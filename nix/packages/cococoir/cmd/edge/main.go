// SPDX-License-Identifier: AGPL-3.0-or-later
// cococoir-edge: VPS-side L4 TCP/UDP forwarder. Receives traffic on
// public IPs and forwards over WireGuard to the customer box where
// cococoir-client hands it to local services. Pure L4; TLS lives
// on the customer's box (Caddy), not on the cococoir data path.
// See PLAN_2.md ADR-006.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ElementalPlaneOfAir/cococoir/nix/packages/cococoir/internal/forwarder"
	"github.com/ElementalPlaneOfAir/cococoir/nix/packages/cococoir/internal/health"
	"github.com/ElementalPlaneOfAir/cococoir/nix/packages/cococoir/internal/logger"
)

type configFile struct {
	Forwards []forwarder.Forward `json:"forwards"`
}

func main() {
	configPath := flag.String("config", "/etc/cococoir-edge.json", "path to cococoir-edge config JSON")
	logFormat := flag.String("log-format", "text", "log format: text or json")
	healthAddr := flag.String("health-addr", "127.0.0.1:9090", "address for /healthz, /readyz, /status; empty disables the health server")
	flag.Parse()

	format, err := logger.ParseFormat(*logFormat)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	lg := format.Build(os.Stderr, "cococoir-edge")

	data, err := os.ReadFile(*configPath)
	if err != nil {
		lg.Error("read config failed", "path", *configPath, "err", err)
		os.Exit(1)
	}
	var cfg configFile
	if err := json.Unmarshal(data, &cfg); err != nil {
		lg.Error("parse config failed", "err", err)
		os.Exit(1)
	}

	f, err := forwarder.New(forwarder.Config{
		Forwards:  cfg.Forwards,
		Logger:    lg,
		Component: "cococoir-edge",
	})
	if err != nil {
		lg.Error("forwarder init failed", "err", err)
		os.Exit(1)
	}

	healthSrv := health.NewServer(*healthAddr, func() any { return f.Stats() }, lg)
	healthDone := make(chan error, 1)
	go func() {
		healthDone <- healthSrv.ListenAndServe()
	}()
	go func() {
		if err := <-healthDone; err != nil && !errors.Is(err, http.ErrServerClosed) {
			lg.Error("health server exited with error", "err", err)
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := f.Run(ctx); err != nil {
		lg.Error("forwarder exited with error", "err", err)
		os.Exit(1)
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = healthSrv.Shutdown(shutdownCtx)
}
