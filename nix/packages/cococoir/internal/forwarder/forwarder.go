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
//
// Logging: the forwarder uses log/slog for structured event output.
// Callers pass a *slog.Logger in Config.Logger. If nil, slog.Default()
// is used (writes to stderr in text format at Info level). The cmd
// entry points configure the logger (component field, optional JSON
// handler) before calling New. See internal/logger.
//
// Observability: the forwarder tracks per-forward bind state and
// active-connection counts. Stats() returns a snapshot intended
// for an HTTP /status endpoint (see internal/health). The forwarder
// does not know about HTTP itself; the cmd entry points wire
// forwarder.Stats into a health.Server via a closure.
package forwarder

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"time"
)

const (
	DefaultShutdownTimeout = 30 * time.Second
	DefaultBindTimeout     = 30 * time.Second
	DefaultUDPFlowIdle     = 5 * time.Minute
)

// Proto is the L4 protocol of a Forward. The string-typed enum
// pattern keeps the JSON config schema human-readable
// (`{"proto": "tcp"}`) while making invalid values a compile
// error in any code that uses the constants directly. New()
// rejects values that aren't ProtoTCP or ProtoUDP.
type Proto string

const (
	ProtoTCP Proto = "tcp"
	ProtoUDP Proto = "udp"
)

type Config struct {
	Forwards        []Forward
	ShutdownTimeout time.Duration
	BindTimeout     time.Duration
	UDPFlowIdle     time.Duration
	Logger          *slog.Logger
	Component       string
}

type Forward struct {
	ListenAddr string `json:"listen_addr"`
	Proto      Proto  `json:"proto"`
	DestAddr   string `json:"dest_addr"`
}

// ConfigError is returned by New when a Forward in cfg fails
// validation. The Index field identifies which forward failed,
// and Unwrap exposes the underlying validation message. Callers
// can use errors.As to inspect; the cmd entry points just log.
type ConfigError struct {
	Index int
	Err   error
}

func (e *ConfigError) Error() string {
	return fmt.Sprintf("forwarder: forwards[%d]: %v", e.Index, e.Err)
}

func (e *ConfigError) Unwrap() error { return e.Err }

// Stats is a point-in-time snapshot of the forwarder's state,
// safe to consume from any goroutine. Returned by Stats(). The
// JSON shape is the contract consumed by the /status endpoint
// (see internal/health) and by future telemetry collectors.
type Stats struct {
	Component     string        `json:"component"`
	StartedAt     time.Time     `json:"started_at"`
	UptimeSeconds float64       `json:"uptime_seconds"`
	Forwards      []ForwardStat `json:"forwards"`
	TCPConns      int64         `json:"tcp_connections"`
	UDPFlows      int64         `json:"udp_flows"`
}

// ForwardStat is the per-forward row in Stats. Either Bound is
// true (the listener is up) or LastError is non-empty (the bind
// failed and was recorded). Both being false is a transient
// state only seen if the forwarder has just been created and
// the bind has not yet completed.
type ForwardStat struct {
	Proto      Proto      `json:"proto"`
	ListenAddr string     `json:"listen_addr"`
	DestAddr   string     `json:"dest_addr"`
	Bound      bool       `json:"bound"`
	BoundAt    *time.Time `json:"bound_at,omitempty"`
	LastError  string     `json:"last_error,omitempty"`
}

type Forwarder struct {
	cfg       Config
	log       *slog.Logger
	listeners []io.Closer
	wg        sync.WaitGroup
	startedAt time.Time
	statsMu   sync.RWMutex
	forwards  map[string]ForwardStat
	tcpConns  int64
	udpFlows  int64
}

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
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.Component == "" {
		cfg.Component = "cococoir"
	}
	for i, fwd := range cfg.Forwards {
		if err := validateForward(fwd); err != nil {
			return nil, &ConfigError{Index: i, Err: err}
		}
	}
	return &Forwarder{
		cfg:       cfg,
		log:       cfg.Logger,
		startedAt: time.Now().UTC(),
		forwards:  make(map[string]ForwardStat),
	}, nil
}

func validateForward(fwd Forward) error {
	if fwd.ListenAddr == "" {
		return errors.New("empty listen_addr")
	}
	if fwd.DestAddr == "" {
		return errors.New("empty dest_addr")
	}
	switch fwd.Proto {
	case ProtoTCP, ProtoUDP:
		return nil
	default:
		return fmt.Errorf("unknown proto %q (want %q or %q)", fwd.Proto, ProtoTCP, ProtoUDP)
	}
}

func (f *Forwarder) Run(ctx context.Context) error {
	for _, fwd := range f.cfg.Forwards {
		if err := f.start(ctx, fwd); err != nil {
			_ = f.shutdown()
			return fmt.Errorf("forwarder: start %s %s: %w", fwd.Proto, fwd.ListenAddr, err)
		}
	}
	f.log.Info("forwarder running", "count", len(f.cfg.Forwards))
	<-ctx.Done()
	f.log.Info("forwarder shutting down", "drain_timeout", f.cfg.ShutdownTimeout)
	return f.shutdown()
}

func (f *Forwarder) start(ctx context.Context, fwd Forward) error {
	switch fwd.Proto {
	case ProtoTCP:
		ln, err := retryListen(ctx, f.cfg.BindTimeout, "tcp", fwd.ListenAddr)
		if err != nil {
			f.recordBindError(fwd, err)
			return err
		}
		f.listeners = append(f.listeners, ln)
		f.recordBound(fwd, time.Now())
		f.log.Info("tcp forward bound", "listen_addr", fwd.ListenAddr, "dest_addr", fwd.DestAddr)
		f.wg.Add(1)
		go func() {
			defer f.wg.Done()
			serveTCP(ln, fwd.DestAddr, f.log, f)
		}()
	case ProtoUDP:
		conn, err := retryListenPacket(ctx, f.cfg.BindTimeout, "udp", fwd.ListenAddr)
		if err != nil {
			f.recordBindError(fwd, err)
			return err
		}
		f.listeners = append(f.listeners, conn)
		f.recordBound(fwd, time.Now())
		f.log.Info("udp forward bound", "listen_addr", fwd.ListenAddr, "dest_addr", fwd.DestAddr)
		f.wg.Add(1)
		go func() {
			defer f.wg.Done()
			serveUDP(conn, fwd.DestAddr, f.cfg.UDPFlowIdle, f.log, f)
		}()
	default:
		return fmt.Errorf("unknown proto %q (impossible: validated in New)", fwd.Proto)
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
		f.log.Info("forwarder drained")
	case <-time.After(f.cfg.ShutdownTimeout):
		f.log.Error("forwarder drain timed out", "drain_timeout", f.cfg.ShutdownTimeout)
	}
	return firstCloseErr
}

// Stats returns a snapshot of the forwarder's current state. Safe
// to call from any goroutine, including HTTP handlers. The slice
// in the returned Stats is a fresh copy; mutating it does not
// affect the forwarder.
func (f *Forwarder) Stats() Stats {
	f.statsMu.RLock()
	defer f.statsMu.RUnlock()
	forwards := make([]ForwardStat, 0, len(f.forwards))
	for _, v := range f.forwards {
		forwards = append(forwards, v)
	}
	return Stats{
		Component:     f.cfg.Component,
		StartedAt:     f.startedAt,
		UptimeSeconds: time.Since(f.startedAt).Seconds(),
		Forwards:      forwards,
		TCPConns:      f.tcpConns,
		UDPFlows:      f.udpFlows,
	}
}

func (f *Forwarder) recordBound(fwd Forward, at time.Time) {
	key := forwardKey(fwd)
	boundAt := at.UTC()
	f.statsMu.Lock()
	defer f.statsMu.Unlock()
	f.forwards[key] = ForwardStat{
		Proto:      fwd.Proto,
		ListenAddr: fwd.ListenAddr,
		DestAddr:   fwd.DestAddr,
		Bound:      true,
		BoundAt:    &boundAt,
	}
}

func (f *Forwarder) recordBindError(fwd Forward, err error) {
	key := forwardKey(fwd)
	f.statsMu.Lock()
	defer f.statsMu.Unlock()
	f.forwards[key] = ForwardStat{
		Proto:      fwd.Proto,
		ListenAddr: fwd.ListenAddr,
		DestAddr:   fwd.DestAddr,
		Bound:      false,
		LastError:  err.Error(),
	}
}

func (f *Forwarder) incTCPConns() {
	f.statsMu.Lock()
	defer f.statsMu.Unlock()
	f.tcpConns++
}

func (f *Forwarder) decTCPConns() {
	f.statsMu.Lock()
	defer f.statsMu.Unlock()
	if f.tcpConns > 0 {
		f.tcpConns--
	}
}

func (f *Forwarder) incUDPFlows() {
	f.statsMu.Lock()
	defer f.statsMu.Unlock()
	f.udpFlows++
}

func (f *Forwarder) decUDPFlows() {
	f.statsMu.Lock()
	defer f.statsMu.Unlock()
	if f.udpFlows > 0 {
		f.udpFlows--
	}
}

func forwardKey(fwd Forward) string {
	return string(fwd.Proto) + "://" + fwd.ListenAddr
}
