// SPDX-License-Identifier: AGPL-3.0-or-later
// Package health serves a small HTTP /healthz, /readyz, and
// /status endpoint. The forwarder calls NewServer with a
// statusFunc closure that returns its current Stats; the health
// server JSON-marshals the value and serves it on /status. The
// health package does not import the forwarder package, so
// either side can evolve without coupling. A future probe
// runner (v0.5 PR 4) can use the same package: implement
// its own statusFunc, pass it to NewServer, get a uniform
// HTTP surface for free.
package health

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"
)

// StatusFunc returns the current state of the service. Called
// on every /readyz and /status request. Should be cheap (a
// mutex-guarded read of in-memory state, not a database query).
type StatusFunc func() any

// Server is the health HTTP server. Construct with NewServer,
// drive with ListenAndServe in a goroutine, release with
// Shutdown. The /healthz endpoint always returns 200 if the
// process is alive (it serves a 1-byte body); /readyz returns
// 200 if statusFunc returns a value whose "Forwards" field
// contains at least one entry with "bound"=true, 503 otherwise;
// /status returns statusFunc's value as JSON.
type Server struct {
	addr       string
	statusFunc StatusFunc
	log        *slog.Logger
	httpServer *http.Server
	listenerMu sync.Mutex
	listener   net.Listener
}

// NewServer returns a Server bound to addr. statusFunc is
// called on every /readyz and /status request. If log is nil,
// slog.Default() is used. addr must be a host:port string
// (e.g. "127.0.0.1:9090"). An empty addr means "health
// server disabled" and the returned Server's ListenAndServe
// returns nil immediately, so cmd entry points can pass an
// operator-controlled value without special-casing.
func NewServer(addr string, statusFunc StatusFunc, log *slog.Logger) *Server {
	if log == nil {
		log = slog.Default()
	}
	s := &Server{
		addr:       addr,
		statusFunc: statusFunc,
		log:        log,
	}
	if addr == "" {
		return s
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/readyz", s.handleReadyz)
	mux.HandleFunc("/status", s.handleStatus)
	s.httpServer = &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	return s
}

// ListenAndServe binds the listener and serves until Shutdown
// is called. Returns nil if addr was empty (server disabled).
// Other errors (e.g. port in use) propagate; the cmd entry
// point should treat a non-nil error as fatal.
func (s *Server) ListenAndServe() error {
	if s.addr == "" {
		s.log.Info("health server disabled (empty addr)")
		return nil
	}
	ln, err := net.Listen("tcp", s.addr)
	if err != nil {
		return fmt.Errorf("health: listen %s: %w", s.addr, err)
	}
	s.listenerMu.Lock()
	s.listener = ln
	s.listenerMu.Unlock()
	s.log.Info("health server listening", "addr", s.addr)
	if err := s.httpServer.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// Addr returns the bound address (after ListenAndServe has
// been called). Useful for tests that want to know which port
// the OS picked when addr was ":0". Returns "" if the server
// is disabled or hasn't started yet.
func (s *Server) Addr() string {
	s.listenerMu.Lock()
	defer s.listenerMu.Unlock()
	if s.listener == nil {
		return ""
	}
	return s.listener.Addr().String()
}

// Shutdown stops the HTTP server gracefully, waiting for
// in-flight requests up to ctx's deadline. Idempotent.
func (s *Server) Shutdown(ctx context.Context) error {
	if s.httpServer == nil {
		return nil
	}
	return s.httpServer.Shutdown(ctx)
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	ready, err := s.readyFromStatus()
	if err != nil {
		s.log.Warn("readyz status func failed", "err", err)
		http.Error(w, "status unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if !ready {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"ready":false}`))
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"ready":true}`))
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.statusFunc == nil {
		http.Error(w, "no status func configured", http.StatusInternalServerError)
		return
	}
	body, err := json.MarshalIndent(s.statusFunc(), "", "  ")
	if err != nil {
		s.log.Warn("status marshal failed", "err", err)
		http.Error(w, "status marshal failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
	_, _ = w.Write([]byte("\n"))
}

// readyFromStatus returns true if the status indicates the
// service is ready to serve traffic. The current contract:
// at least one entry in the "forwards" list has "bound"=true.
// We accept any "forwards"-shaped object and look for the
// "bound" boolean via a small unmarshal pass. This keeps
// the health package independent of the forwarder types.
func (s *Server) readyFromStatus() (bool, error) {
	if s.statusFunc == nil {
		return false, nil
	}
	raw, err := json.Marshal(s.statusFunc())
	if err != nil {
		return false, err
	}
	var probe struct {
		Forwards []struct {
			Bound bool `json:"bound"`
		} `json:"forwards"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return false, fmt.Errorf("readyz: parse status: %w", err)
	}
	for _, f := range probe.Forwards {
		if f.Bound {
			return true, nil
		}
	}
	return false, nil
}
