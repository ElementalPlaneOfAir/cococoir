// SPDX-License-Identifier: AGPL-3.0-or-later
// cococoir-client: customer-box-side L4 TCP/UDP forwarder. Receives
// traffic from cococoir-edge over WireGuard and forwards to
// 127.0.0.1:<port> where local Caddy terminates TLS. Pure L4; the
// Caddy on the customer's box owns TLS. See PLAN_2.md ADR-006.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/ElementalPlaneOfAir/cococoir/nix/packages/cococoir/internal/forwarder"
)

type configFile struct {
	Forwards []forwarder.Forward `json:"forwards"`
}

func main() {
	configPath := flag.String("config", "/etc/cococoir-client.json", "path to cococoir-client config JSON")
	flag.Parse()

	log.SetPrefix("cococoir-client ")

	data, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatalf("read config %q: %v", *configPath, err)
	}
	var cfg configFile
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Fatalf("parse config: %v", err)
	}

	f, err := forwarder.New(forwarder.Config{Forwards: cfg.Forwards})
	if err != nil {
		log.Fatalf("forwarder: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := f.Run(ctx); err != nil {
		log.Fatalf("forwarder: %v", err)
	}
}
