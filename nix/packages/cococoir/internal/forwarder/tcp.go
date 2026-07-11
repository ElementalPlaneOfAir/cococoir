// SPDX-License-Identifier: AGPL-3.0-or-later
package forwarder

import (
	"io"
	"log/slog"
	"net"
)

func serveTCP(ln net.Listener, destAddr string, log *slog.Logger) {
	for {
		src, err := ln.Accept()
		if err != nil {
			log.Warn("accept failed", "addr", ln.Addr().String(), "err", err)
			return
		}
		go handleTCPConn(src, destAddr, log)
	}
}

func handleTCPConn(src net.Conn, destAddr string, log *slog.Logger) {
	defer src.Close()
	dst, err := net.Dial("tcp", destAddr)
	if err != nil {
		log.Error("dial tcp failed", "dest_addr", destAddr, "err", err)
		return
	}
	defer dst.Close()
	log.Info("tcp connection opened", "src", src.RemoteAddr().String(), "dest", destAddr)
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(dst, src); done <- struct{}{} }()
	go func() { _, _ = io.Copy(src, dst); done <- struct{}{} }()
	<-done
	log.Info("tcp connection closed", "src", src.RemoteAddr().String(), "dest", destAddr)
}
