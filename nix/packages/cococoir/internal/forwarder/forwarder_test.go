// SPDX-License-Identifier: AGPL-3.0-or-later
package forwarder

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"syscall"
	"testing"
	"time"
)

func TestNew_EmptyForwards(t *testing.T) {
	_, err := New(Config{Forwards: nil})
	if err == nil {
		t.Fatal("New with no forwards: expected error, got nil")
	}
}

func TestNew_UnknownProto(t *testing.T) {
	_, err := New(Config{Forwards: []Forward{{ListenAddr: "127.0.0.1:0", Proto: "sctp", DestAddr: "127.0.0.1:0"}}})
	if err == nil {
		t.Fatal("New with unknown proto: expected error, got nil")
	}
}

func TestNew_MissingFields(t *testing.T) {
	cases := []struct {
		name string
		fwd  Forward
	}{
		{"empty listen", Forward{Proto: "tcp", DestAddr: "127.0.0.1:1"}},
		{"empty dest", Forward{Proto: "tcp", ListenAddr: "127.0.0.1:1"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := New(Config{Forwards: []Forward{c.fwd}}); err == nil {
				t.Fatal("expected error for missing field, got nil")
			}
		})
	}
}

func TestRun_TCPForward(t *testing.T) {
	upstreamPort := pickFreeTCPPort(t)
	upstream, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", upstreamPort))
	if err != nil {
		t.Fatalf("upstream listen: %v", err)
	}
	t.Cleanup(func() { _ = upstream.Close() })
	go echoTCP(upstream)

	fwdPort := pickFreeTCPPort(t)
	f, err := New(Config{Forwards: []Forward{{
		Proto:      "tcp",
		ListenAddr: fmt.Sprintf("127.0.0.1:%d", fwdPort),
		DestAddr:   upstream.Addr().String(),
	}}})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	_ = runForwarder(t, f)

	msg := []byte("ping")
	got := roundTripTCP(t, fwdPort, msg, 2*time.Second)
	if !bytes.Equal(msg, got) {
		t.Errorf("tcp round-trip: got %q, want %q", got, msg)
	}
}

func TestRun_UDPForward(t *testing.T) {
	upstreamAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	upstream, err := net.ListenUDP("udp", upstreamAddr)
	if err != nil {
		t.Fatalf("upstream listen: %v", err)
	}
	t.Cleanup(func() { _ = upstream.Close() })
	go echoUDP(upstream)

	fwdPort := pickFreeUDPPort(t)
	f, err := New(Config{Forwards: []Forward{{
		Proto:      "udp",
		ListenAddr: fmt.Sprintf("127.0.0.1:%d", fwdPort),
		DestAddr:   upstream.LocalAddr().String(),
	}}})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	_ = runForwarder(t, f)

	msg := []byte("ping")
	got := roundTripUDP(t, fwdPort, msg, 2*time.Second)
	if !bytes.Equal(msg, got) {
		t.Errorf("udp round-trip: got %q, want %q", got, msg)
	}
}

func TestRun_GracefulShutdownNoInflight(t *testing.T) {
	fwdPort := pickFreeTCPPort(t)
	upstream, _ := net.Listen("tcp", "127.0.0.1:0")
	_ = upstream.Close()
	f, err := New(Config{
		Forwards:        []Forward{{Proto: "tcp", ListenAddr: fmt.Sprintf("127.0.0.1:%d", fwdPort), DestAddr: "127.0.0.1:1"}},
		ShutdownTimeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	_ = runForwarder(t, f)
}

func TestRun_RetryUntilContextCancel(t *testing.T) {
	f, err := New(Config{
		Forwards: []Forward{{
			Proto:      "tcp",
			ListenAddr: "192.0.2.1:80",
			DestAddr:   "127.0.0.1:80",
		}},
		BindTimeout: 30 * time.Second,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runErr := make(chan error, 1)
	go func() { runErr <- f.Run(ctx) }()

	time.Sleep(200 * time.Millisecond)
	cancel()

	select {
	case err := <-runErr:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("Run after cancel: got %v, want context.Canceled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
}

func TestIsTransientBindErr(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"EADDRNOTAVAIL", syscall.EADDRNOTAVAIL, true},
		{"ENETDOWN", syscall.ENETDOWN, true},
		{"ENETUNREACH", syscall.ENETUNREACH, true},
		{"unrelated", errors.New("some other error"), false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := isTransientBindErr(c.err)
			if got != c.want {
				t.Errorf("isTransientBindErr(%v) = %v, want %v", c.err, got, c.want)
			}
		})
	}
}

func TestNextBackoff(t *testing.T) {
	cases := []struct {
		in, want time.Duration
	}{
		{retryBackoffStart, retryBackoffStart * 2},
		{retryBackoffMax, retryBackoffMax},
		{retryBackoffMax * 2, retryBackoffMax},
	}
	for _, c := range cases {
		if got := nextBackoff(c.in); got != c.want {
			t.Errorf("nextBackoff(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

func pickFreeTCPPort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("pick free tcp port: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return port
}

func pickFreeUDPPort(t *testing.T) int {
	t.Helper()
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatalf("pick free udp port: %v", err)
	}
	port := conn.LocalAddr().(*net.UDPAddr).Port
	_ = conn.Close()
	return port
}

func echoTCP(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func(c net.Conn) {
			defer c.Close()
			_, _ = io.Copy(c, c)
		}(c)
	}
}

func echoUDP(c *net.UDPConn) {
	buf := make([]byte, 65535)
	for {
		n, src, err := c.ReadFromUDP(buf)
		if err != nil {
			return
		}
		_, _ = c.WriteToUDP(buf[:n], src)
	}
}

func roundTripTCP(t *testing.T, port int, msg []byte, timeout time.Duration) []byte {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			defer c.Close()
			c.SetDeadline(time.Now().Add(timeout))
			if _, err := c.Write(msg); err != nil {
				t.Fatalf("write: %v", err)
			}
			buf := make([]byte, len(msg))
			if _, err := io.ReadFull(c, buf); err != nil {
				t.Fatalf("read: %v", err)
			}
			return buf
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("could not connect to forwarder on port %d", port)
	return nil
}

func roundTripUDP(t *testing.T, port int, msg []byte, timeout time.Duration) []byte {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		c, err := net.DialUDP("udp", nil, &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: port})
		if err != nil {
			lastErr = err
			time.Sleep(10 * time.Millisecond)
			continue
		}
		if _, err := c.Write(msg); err != nil {
			_ = c.Close()
			lastErr = err
			time.Sleep(10 * time.Millisecond)
			continue
		}
		c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		buf := make([]byte, 65535)
		n, err := c.Read(buf)
		_ = c.Close()
		if err != nil {
			lastErr = err
			time.Sleep(10 * time.Millisecond)
			continue
		}
		return buf[:n]
	}
	t.Fatalf("udp round-trip on port %d after %v: %v", port, timeout, lastErr)
	return nil
}

func runForwarder(t *testing.T, f *Forwarder) chan error {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	runErr := make(chan error, 1)
	go func() { runErr <- f.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-runErr:
		case <-time.After(5 * time.Second):
			t.Log("forwarder did not return within 5s after cancel")
		}
	})
	return runErr
}
