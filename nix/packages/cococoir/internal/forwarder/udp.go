// SPDX-License-Identifier: AGPL-3.0-or-later
package forwarder

import (
	"log/slog"
	"net"
	"sync"
	"time"
)

type udpFlow struct {
	dst  *net.UDPConn
	last time.Time
}

const udpExpireCheckIntervalCap = 60 * time.Second

func serveUDP(ln *net.UDPConn, destAddr string, idleTimeout time.Duration, log *slog.Logger, f *Forwarder) {
	dst, err := net.ResolveUDPAddr("udp", destAddr)
	if err != nil {
		log.Error("resolve udp failed", "dest_addr", destAddr, "err", err)
		return
	}
	var mu sync.Mutex
	flows := make(map[string]*udpFlow)

	checkInterval := idleTimeout / 2
	if checkInterval > udpExpireCheckIntervalCap {
		checkInterval = udpExpireCheckIntervalCap
	}
	if checkInterval > 0 {
		go expireIdleFlows(&mu, flows, idleTimeout, checkInterval, log, f)
	}

	buf := make([]byte, 65535)
	for {
		n, src, err := ln.ReadFromUDP(buf)
		if err != nil {
			log.Warn("read udp failed", "addr", ln.LocalAddr().String(), "err", err)
			return
		}
		key := src.String()
		mu.Lock()
		fl, ok := flows[key]
		if !ok {
			dc, err := net.DialUDP("udp", nil, dst)
			if err != nil {
				mu.Unlock()
				log.Error("dial udp failed", "dest_addr", destAddr, "err", err)
				continue
			}
			fl = &udpFlow{dst: dc, last: time.Now()}
			flows[key] = fl
			log.Info("udp flow opened", "src", key, "dest", destAddr)
			f.incUDPFlows()
			go relayUDPResponses(ln, dc, src, key, &mu, flows, log, f)
		}
		fl.last = time.Now()
		mu.Unlock()
		if _, err := fl.dst.Write(buf[:n]); err != nil {
			log.Error("write udp failed", "dest_addr", destAddr, "err", err)
		}
	}
}

func relayUDPResponses(ln *net.UDPConn, dc *net.UDPConn, srcAddr *net.UDPAddr, key string, mu *sync.Mutex, flows map[string]*udpFlow, log *slog.Logger, f *Forwarder) {
	rbuf := make([]byte, 65535)
	for {
		m, err := dc.Read(rbuf)
		if err != nil {
			mu.Lock()
			if _, present := flows[key]; present {
				delete(flows, key)
				f.decUDPFlows()
			}
			mu.Unlock()
			log.Info("udp flow relay exited", "src", key, "err", err)
			return
		}
		if _, err := ln.WriteToUDP(rbuf[:m], srcAddr); err != nil {
			log.Warn("udp relay write failed", "src", key, "err", err)
			return
		}
		mu.Lock()
		if existing, ok := flows[key]; ok {
			existing.last = time.Now()
		}
		mu.Unlock()
	}
}

func expireIdleFlows(mu *sync.Mutex, flows map[string]*udpFlow, idleTimeout, checkInterval time.Duration, log *slog.Logger, f *Forwarder) {
	ticker := time.NewTicker(checkInterval)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		mu.Lock()
		for k, fl := range flows {
			if now.Sub(fl.last) > idleTimeout {
				_ = fl.dst.Close()
				delete(flows, k)
				f.decUDPFlows()
				log.Info("udp flow expired", "src", k)
			}
		}
		mu.Unlock()
	}
}
