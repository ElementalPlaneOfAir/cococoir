// SPDX-License-Identifier: AGPL-3.0-or-later
package forwarder

import (
	"io"
	"log"
	"net"
)

func serveTCP(ln net.Listener, destAddr string) {
	for {
		src, err := ln.Accept()
		if err != nil {
			log.Printf("forwarder: accept %s: %v", ln.Addr(), err)
			return
		}
		go handleTCPConn(src, destAddr)
	}
}

func handleTCPConn(src net.Conn, destAddr string) {
	defer src.Close()
	dst, err := net.Dial("tcp", destAddr)
	if err != nil {
		log.Printf("forwarder: dial tcp %s: %v", destAddr, err)
		return
	}
	defer dst.Close()
	log.Printf("forwarder: tcp conn %s <-> %s", src.RemoteAddr(), destAddr)
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(dst, src); done <- struct{}{} }()
	go func() { _, _ = io.Copy(src, dst); done <- struct{}{} }()
	<-done
	log.Printf("forwarder: tcp conn %s <-> %s closed", src.RemoteAddr(), destAddr)
}
