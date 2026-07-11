// SPDX-License-Identifier: AGPL-3.0-or-later
// Package forwarder is the shared L4 TCP/UDP forwarder used by both
// cococoir-edge (VPS) and cococoir-client (customer box). The two
// binaries are thin wrappers around this package: they parse a JSON
// config of {forwards: [{listen_addr, proto, dest_addr}, ...]} and
// hand the slice to a *Forwarder.
//
// Design: New() validates the config; Run(ctx) binds all listeners,
// blocks until ctx is cancelled, then performs graceful shutdown
// (close listeners, wait for in-flight conns to drain with a timeout).
// No background goroutines leak on shutdown.
package forwarder

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
	"time"
)

const (
	DefaultShutdownTimeout = 30 * time.Second
	DefaultBindTimeout     = 30 * time.Second
	DefaultUDPFlowIdle     = 5 * time.Minute
	udpExpireCheckInterval = 60 * time.Second
)

// Config is the input to New. Forwards is required; the timeouts and
// the UDP flow idle duration fall back to the Default* values when
// zero, so callers can leave them unset.
type Config struct {
	Forwards        []Forward
	ShutdownTimeout time.Duration
	BindTimeout     time.Duration
	UDPFlowIdle     time.Duration
}

// Forward is one L4 forwarding rule. ListenAddr is host:port; for
// the edge it is typically a public IP:port, for the client it is
// typically the WireGuard interface IP:port. DestAddr is host:port
// of the upstream (for the edge, the customer's box over WG; for the
// client, 127.0.0.1:<port> where local Caddy terminates TLS).
type Forward struct {
	ListenAddr string `json:"listen_addr"`
	Proto      string `json:"proto"`
	DestAddr   string `json:"dest_addr"`
}

// Forwarder is the live L4 forwarder. Construct with New, drive with
// Run, never reuse after Run returns.
type Forwarder struct {
	cfg       Config
	listeners []io.Closer
	wg        sync.WaitGroup
}

// New validates cfg and returns a *Forwarder. It does not bind any
// listeners; binding happens in Run so a failed bind is reported via
// Run's return value rather than New.
func New(cfg Config) (*Forwarder, error) {
	if len(cfg.Forwards) == 0 {
		return nil, errors.New("forwarder: no forwards in config")
	}
	if cfg.ShutdownTimeout == 0 {
		cfg.ShutdownTimeout = DefaultShutdownTimeout
	}
	if cfg.BindTimeout == 0 {
		cfg.BindTimeout = DefaultBindTimeout
	}
	if cfg.UDPFlowIdle == 0 {
		cfg.UDPFlowIdle = DefaultUDPFlowIdle
	}
	for i, fwd := range cfg.Forwards {
		if fwd.ListenAddr == "" {
			return nil, fmt.Errorf("forwarder: forwards[%d]: empty listen_addr", i)
		}
		if fwd.DestAddr == "" {
			return nil, fmt.Errorf("forwarder: forwards[%d]: empty dest_addr", i)
		}
		switch fwd.Proto {
		case "tcp", "udp":
		default:
			return nil, fmt.Errorf("forwarder: forwards[%d]: unknown proto %q (want tcp or udp)", i, fwd.Proto)
		}
	}
	return &Forwarder{cfg: cfg}, nil
}

// Run binds every forward in cfg, then blocks until ctx is cancelled,
// then performs graceful shutdown. Returns nil on a clean shutdown, an
// error if any listener failed to bind within BindTimeout, or ctx.Err()
// if ctx was cancelled mid-bind.
func (f *Forwarder) Run(ctx context.Context) error {
	for _, fwd := range f.cfg.Forwards {
		if err := f.start(ctx, fwd); err != nil {
			_ = f.shutdown()
			return fmt.Errorf("forwarder: start %s %s: %w", fwd.Proto, fwd.ListenAddr, err)
		}
	}
	log.Printf("forwarder: running %d forward(s)", len(f.cfg.Forwards))
	<-ctx.Done()
	log.Printf("forwarder: shutting down (drain timeout %v)", f.cfg.ShutdownTimeout)
	return f.shutdown()
}

func (f *Forwarder) start(ctx context.Context, fwd Forward) error {
	switch fwd.Proto {
	case "tcp":
		ln, err := retryListen(ctx, f.cfg.BindTimeout, "tcp", fwd.ListenAddr)
		if err != nil {
			return err
		}
		f.listeners = append(f.listeners, ln)
		log.Printf("forwarder: tcp %s -> %s", fwd.ListenAddr, fwd.DestAddr)
		f.wg.Add(1)
		go func() {
			defer f.wg.Done()
			serveTCP(ln, fwd.DestAddr)
		}()
	case "udp":
		conn, err := retryListenPacket(ctx, f.cfg.BindTimeout, "udp", fwd.ListenAddr)
		if err != nil {
			return err
		}
		f.listeners = append(f.listeners, conn)
		log.Printf("forwarder: udp %s -> %s", fwd.ListenAddr, fwd.DestAddr)
		f.wg.Add(1)
		go func() {
			defer f.wg.Done()
			serveUDP(conn, fwd.DestAddr, f.cfg.UDPFlowIdle)
		}()
	default:
		return fmt.Errorf("unknown proto %q", fwd.Proto)
	}
	return nil
}

func (f *Forwarder) shutdown() error {
	var firstCloseErr error
	for _, c := range f.listeners {
		if err := c.Close(); err != nil && firstCloseErr == nil {
			firstCloseErr = err
		}
	}
	drained := make(chan struct{})
	go func() {
		f.wg.Wait()
		close(drained)
	}()
	select {
	case <-drained:
		log.Printf("forwarder: drained cleanly")
	case <-time.After(f.cfg.ShutdownTimeout):
		log.Printf("forwarder: drain timed out after %v, exiting anyway", f.cfg.ShutdownTimeout)
	}
	return firstCloseErr
}
