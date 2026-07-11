// SPDX-License-Identifier: AGPL-3.0-or-later
package forwarder

import (
	"log"
	"net"
	"sync"
	"time"
)

type udpFlow struct {
	dst  *net.UDPConn
	last time.Time
}

func serveUDP(ln *net.UDPConn, destAddr string, idleTimeout time.Duration) {
	dst, err := net.ResolveUDPAddr("udp", destAddr)
	if err != nil {
		log.Printf("forwarder: resolve udp %s: %v", destAddr, err)
		return
	}
	var mu sync.Mutex
	flows := make(map[string]*udpFlow)

	go expireIdleFlows(&mu, flows, idleTimeout)

	buf := make([]byte, 65535)
	for {
		n, src, err := ln.ReadFromUDP(buf)
		if err != nil {
			log.Printf("forwarder: read udp %s: %v", ln.LocalAddr(), err)
			return
		}
		key := src.String()
		mu.Lock()
		fl, ok := flows[key]
		if !ok {
			dc, err := net.DialUDP("udp", nil, dst)
			if err != nil {
				mu.Unlock()
				log.Printf("forwarder: dial udp %s: %v", destAddr, err)
				continue
			}
			fl = &udpFlow{dst: dc, last: time.Now()}
			flows[key] = fl
			log.Printf("forwarder: udp flow %s <-> %s", key, destAddr)
			go relayUDPResponses(ln, dc, src, key, &mu, flows)
		}
		fl.last = time.Now()
		mu.Unlock()
		if _, err := fl.dst.Write(buf[:n]); err != nil {
			log.Printf("forwarder: write udp %s: %v", destAddr, err)
		}
	}
}

func relayUDPResponses(ln *net.UDPConn, dc *net.UDPConn, srcAddr *net.UDPAddr, key string, mu *sync.Mutex, flows map[string]*udpFlow) {
	rbuf := make([]byte, 65535)
	for {
		m, err := dc.Read(rbuf)
		if err != nil {
			return
		}
		if _, err := ln.WriteToUDP(rbuf[:m], srcAddr); err != nil {
			return
		}
		mu.Lock()
		if f, ok := flows[key]; ok {
			f.last = time.Now()
		}
		mu.Unlock()
	}
}

func expireIdleFlows(mu *sync.Mutex, flows map[string]*udpFlow, idleTimeout time.Duration) {
	ticker := time.NewTicker(udpExpireCheckInterval)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		mu.Lock()
		for k, fl := range flows {
			if now.Sub(fl.last) > idleTimeout {
				_ = fl.dst.Close()
				delete(flows, k)
				log.Printf("forwarder: udp expire flow %s", k)
			}
		}
		mu.Unlock()
	}
}
