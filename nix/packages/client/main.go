// SPDX-License-Identifier: AGPL-3.0-or-later
// cococoir-client: TCP/UDP L4 forwarder for the v2 client service.
//
// Runs on the customer box. Receives traffic from cococoir-edge over
// the WireGuard tunnel and forwards it to 127.0.0.1:<port> where the
// local Caddy terminates TLS. Pure L4: no TLS, no L7 inspection, no
// SNI/Host routing. The Caddy on the customer's box owns TLS; this
// binary is a dumb pipe over the WG interface. See PLAN.md ADR-006.
//
// v0: this is a deliberate copy of the edge forwarder
// (nix/packages/edge/main.go) with a different config path and binary
// name. v0.5 PR 1 will refactor both into a shared internal package.
// For now the duplication is bounded (~225 lines, stdlib-only) and the
// two roles are cleanly separated by their NixOS modules
// (nix/nixos-modules/{edge,client}.nix).
//
// Config schema:
//
//   {
//     "forwards": [
//       { "listen_addr": "10.10.0.2:443", "proto": "tcp", "dest_addr": "127.0.0.1:443" },
//       { "listen_addr": "10.10.0.2:443", "proto": "udp", "dest_addr": "127.0.0.1:443" }
//     ]
//   }
package main

import (
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// Config is the JSON document read from -config.
type Config struct {
	Forwards []Forward `json:"forwards"`
}

// Forward is one L4 forwarding rule.
type Forward struct {
	ListenAddr string `json:"listen_addr"` // host:port to listen on (typically the WG IP)
	Proto      string `json:"proto"`       // "tcp" or "udp"
	DestAddr   string `json:"dest_addr"`   // host:port to forward to (typically 127.0.0.1:<port>)
}

func main() {
	var configPath string
	flag.StringVar(&configPath, "config", "/etc/cococoir/client.json", "path to client.json")
	flag.Parse()

	data, err := os.ReadFile(configPath)
	if err != nil {
		log.Fatalf("read config %q: %v", configPath, err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Fatalf("parse config: %v", err)
	}
	if len(cfg.Forwards) == 0 {
		log.Fatalf("no forwards in config %q", configPath)
	}

	var closers []io.Closer
	var wg sync.WaitGroup
	for _, f := range cfg.Forwards {
		f := f
		switch f.Proto {
		case "tcp":
			ln, err := net.Listen("tcp", f.ListenAddr)
			if err != nil {
				log.Fatalf("listen tcp %s: %v", f.ListenAddr, err)
			}
			closers = append(closers, ln)
			log.Printf("cococoir-client tcp forward: %s -> %s", f.ListenAddr, f.DestAddr)
			wg.Add(1)
			go func() {
				defer wg.Done()
				serveTCP(ln, f.DestAddr)
			}()
		case "udp":
			conn, err := net.ListenPacket("udp", f.ListenAddr)
			if err != nil {
				log.Fatalf("listen udp %s: %v", f.ListenAddr, err)
			}
			closers = append(closers, conn)
			log.Printf("cococoir-client udp forward: %s -> %s", f.ListenAddr, f.DestAddr)
			wg.Add(1)
			go func() {
				defer wg.Done()
				serveUDP(conn.(*net.UDPConn), f.DestAddr)
			}()
		default:
			log.Fatalf("unknown proto %q in forward %+v", f.Proto, f)
		}
	}

	log.Printf("cococoir-client running: %d forward(s)", len(cfg.Forwards))

	sigc := make(chan os.Signal, 1)
	signal.Notify(sigc, syscall.SIGINT, syscall.SIGTERM)
	<-sigc
	log.Printf("shutting down...")
	for _, c := range closers {
		_ = c.Close()
	}
	wg.Wait()
}

// serveTCP accepts incoming TCP connections and pipes each to destAddr.
func serveTCP(ln net.Listener, destAddr string) {
	for {
		src, err := ln.Accept()
		if err != nil {
			log.Printf("accept %s: %v", ln.Addr(), err)
			return
		}
		go handleTCPConn(src, destAddr)
	}
}

func handleTCPConn(src net.Conn, destAddr string) {
	defer src.Close()
	dst, err := net.Dial("tcp", destAddr)
	if err != nil {
		log.Printf("dial tcp %s: %v", destAddr, err)
		return
	}
	defer dst.Close()

	log.Printf("tcp conn %s <-> %s", src.RemoteAddr(), destAddr)
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(dst, src); done <- struct{}{} }()
	go func() { _, _ = io.Copy(src, dst); done <- struct{}{} }()
	<-done
	log.Printf("tcp conn %s <-> %s closed", src.RemoteAddr(), destAddr)
}

// udpFlow is one per-source dial to destAddr.
type udpFlow struct {
	dst  *net.UDPConn
	last time.Time
}

// serveUDP forwards UDP packets between ln and per-source dials to
// destAddr. Each unique source addr gets a fresh UDP dial; dials idle
// for more than 5 minutes are expired. This is sufficient for HTTP/3
// QUIC connections, which multiplex many streams on one UDP 4-tuple.
func serveUDP(ln *net.UDPConn, destAddr string) {
	dst, err := net.ResolveUDPAddr("udp", destAddr)
	if err != nil {
		log.Fatalf("resolve udp %s: %v", destAddr, err)
	}

	var mu sync.Mutex
	flows := make(map[string]*udpFlow)

	go func() {
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			now := time.Now()
			mu.Lock()
			for k, fl := range flows {
				if now.Sub(fl.last) > 5*time.Minute {
					_ = fl.dst.Close()
					delete(flows, k)
					log.Printf("udp expire flow %s", k)
				}
			}
			mu.Unlock()
		}
	}()

	buf := make([]byte, 65535)
	for {
		n, src, err := ln.ReadFromUDP(buf)
		if err != nil {
			log.Printf("read udp %s: %v", ln.LocalAddr(), err)
			return
		}
		key := src.String()

		mu.Lock()
		fl, ok := flows[key]
		if !ok {
			dc, err := net.DialUDP("udp", nil, dst)
			if err != nil {
				mu.Unlock()
				log.Printf("dial udp %s: %v", destAddr, err)
				continue
			}
			fl = &udpFlow{dst: dc, last: time.Now()}
			flows[key] = fl
			log.Printf("udp flow %s <-> %s", key, destAddr)

			go func(srcAddr *net.UDPAddr, k string) {
				rbuf := make([]byte, 65535)
				for {
					m, err := dc.Read(rbuf)
					if err != nil {
						return
					}
					_, _ = ln.WriteToUDP(rbuf[:m], srcAddr)
					mu.Lock()
					if f, ok := flows[k]; ok {
						f.last = time.Now()
					}
					mu.Unlock()
				}
			}(src, key)
		}
		fl.last = time.Now()
		mu.Unlock()

		_, err = fl.dst.Write(buf[:n])
		if err != nil {
			log.Printf("write udp %s: %v", destAddr, err)
		}
	}
}
