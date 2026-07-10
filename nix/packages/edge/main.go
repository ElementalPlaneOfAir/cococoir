// SPDX-License-Identifier: AGPL-3.0-or-later
// cococoir-edge: TCP/UDP L4 forwarder for the v2 edge service.
//
// Reads a JSON config of {listen, proto, dest} forwards and proxies
// traffic between them. Pure L4: no TLS termination, no L7 inspection,
// no SNI/Host routing. The customer's Caddy owns TLS; this is a dumb
// pipe. See PLAN.md ADR-006.
//
// v0 (Day 7-8): no hot-reload. NixOS config change regenerates edge.json
// and `systemd restart cococoir-edge` picks up the new listeners.
//
// Config schema:
//
//   {
//     "forwards": [
//       { "listen_addr": "1.2.3.4:80",  "proto": "tcp", "dest_addr": "10.10.0.2:80" },
//       { "listen_addr": "1.2.3.4:443", "proto": "tcp", "dest_addr": "10.10.0.2:443" },
//       { "listen_addr": "1.2.3.4:443", "proto": "udp", "dest_addr": "10.10.0.2:443" }
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
	ListenAddr string `json:"listen_addr"` // host:port to listen on
	Proto      string `json:"proto"`        // "tcp" or "udp"
	DestAddr   string `json:"dest_addr"`   // host:port to forward to
}

func main() {
	var configPath string
	flag.StringVar(&configPath, "config", "/etc/cococoir/edge.json", "path to edge.json")
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
			log.Printf("tcp forward: %s -> %s", f.ListenAddr, f.DestAddr)
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
			log.Printf("udp forward: %s -> %s", f.ListenAddr, f.DestAddr)
			wg.Add(1)
			go func() {
				defer wg.Done()
				serveUDP(conn.(*net.UDPConn), f.DestAddr)
			}()
		default:
			log.Fatalf("unknown proto %q in forward %+v", f.Proto, f)
		}
	}

	log.Printf("cococoir-edge running: %d forward(s)", len(cfg.Forwards))

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

	// Idle expiry: every 60s, close dials idle > 5min.
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

			// Reads responses from dst, writes them back to src via ln.
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