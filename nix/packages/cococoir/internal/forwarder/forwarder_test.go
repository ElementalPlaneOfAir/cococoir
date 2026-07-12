// SPDX-License-Identifier: AGPL-3.0-or-later
package forwarder

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"syscall"
	"testing"
	"time"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

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
	var ce *ConfigError
	if !errors.As(err, &ce) {
		t.Fatalf("expected *ConfigError, got %T: %v", err, err)
	}
	if ce.Index != 0 {
		t.Errorf("ConfigError.Index = %d, want 0", ce.Index)
	}
}

func TestNew_MissingFields(t *testing.T) {
	cases := []struct {
		name string
		fwd  Forward
	}{
		{"empty listen", Forward{Proto: ProtoTCP, DestAddr: "127.0.0.1:1"}},
		{"empty dest", Forward{Proto: ProtoTCP, ListenAddr: "127.0.0.1:1"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := New(Config{Forwards: []Forward{c.fwd}})
			if err == nil {
				t.Fatal("expected error for missing field, got nil")
			}
			var ce *ConfigError
			if !errors.As(err, &ce) {
				t.Errorf("expected *ConfigError, got %T: %v", err, err)
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
	}}, Logger: discardLogger()})
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
	}}, Logger: discardLogger()})
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
		Logger:          discardLogger(),
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
		Logger:      discardLogger(),
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

func TestStats_DefaultComponent(t *testing.T) {
	f, err := New(Config{Forwards: []Forward{{Proto: ProtoTCP, ListenAddr: "127.0.0.1:0", DestAddr: "127.0.0.1:1"}}, Logger: discardLogger()})
	if err != nil {
		t.Fatal(err)
	}
	if got := f.cfg.Component; got != "cococoir" {
		t.Errorf("default Component = %q, want %q", got, "cococoir")
	}
}

func TestStats_CustomComponent(t *testing.T) {
	f, err := New(Config{
		Forwards:  []Forward{{Proto: ProtoTCP, ListenAddr: "127.0.0.1:0", DestAddr: "127.0.0.1:1"}},
		Component: "cococoir-edge",
		Logger:    discardLogger(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := f.Stats().Component; got != "cococoir-edge" {
		t.Errorf("Stats().Component = %q, want %q", got, "cococoir-edge")
	}
}

func TestStats_InitialState(t *testing.T) {
	f, err := New(Config{
		Forwards: []Forward{{Proto: ProtoTCP, ListenAddr: "127.0.0.1:0", DestAddr: "127.0.0.1:1"}},
		Logger:   discardLogger(),
	})
	if err != nil {
		t.Fatal(err)
	}
	stats := f.Stats()
	if stats.Component != "cococoir" {
		t.Errorf("Component = %q, want %q", stats.Component, "cococoir")
	}
	if stats.TCPConns != 0 {
		t.Errorf("TCPConns = %d, want 0", stats.TCPConns)
	}
	if stats.UDPFlows != 0 {
		t.Errorf("UDPFlows = %d, want 0", stats.UDPFlows)
	}
	if len(stats.Forwards) != 0 {
		t.Errorf("Forwards = %d, want 0 (no binds yet)", len(stats.Forwards))
	}
	if stats.StartedAt.IsZero() {
		t.Error("StartedAt is zero")
	}
	if stats.UptimeSeconds < 0 {
		t.Errorf("UptimeSeconds = %v, want >= 0", stats.UptimeSeconds)
	}
}

func TestStats_RecordsBoundForward(t *testing.T) {
	port := pickFreeTCPPort(t)
	upstream, _ := net.Listen("tcp", "127.0.0.1:0")
	_ = upstream.Close()
	f, err := New(Config{
		Forwards: []Forward{{
			Proto:      ProtoTCP,
			ListenAddr: fmt.Sprintf("127.0.0.1:%d", port),
			DestAddr:   upstream.Addr().String(),
		}},
		Component: "cococoir-edge",
		Logger:    discardLogger(),
	})
	if err != nil {
		t.Fatal(err)
	}
	_ = runForwarder(t, f)

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		stats := f.Stats()
		if len(stats.Forwards) == 1 && stats.Forwards[0].Bound {
			if !stats.Forwards[0].BoundAt.After(time.Time{}) {
				t.Error("BoundAt is zero, want a real time")
			}
			if stats.Forwards[0].LastError != "" {
				t.Errorf("LastError = %q, want empty", stats.Forwards[0].LastError)
			}
			if stats.Forwards[0].ListenAddr != fmt.Sprintf("127.0.0.1:%d", port) {
				t.Errorf("ListenAddr = %q, want %q", stats.Forwards[0].ListenAddr, fmt.Sprintf("127.0.0.1:%d", port))
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("forwarder never recorded bound state; stats = %+v", f.Stats())
}

func TestStats_RecordsBindError(t *testing.T) {
	f, err := New(Config{
		Forwards: []Forward{{
			Proto:      ProtoTCP,
			ListenAddr: "192.0.2.1:80",
			DestAddr:   "127.0.0.1:80",
		}},
		BindTimeout: 100 * time.Millisecond,
		Logger:      discardLogger(),
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runErr := make(chan error, 1)
	go func() { runErr <- f.Run(ctx) }()

	select {
	case <-runErr:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after BindTimeout expired")
	}

	stats := f.Stats()
	if len(stats.Forwards) != 1 {
		t.Fatalf("Forwards = %d, want 1", len(stats.Forwards))
	}
	fs := stats.Forwards[0]
	if fs.Bound {
		t.Error("Bound = true, want false")
	}
	if fs.LastError == "" {
		t.Error("LastError is empty, want a bind error message")
	}
	if fs.BoundAt != nil {
		t.Errorf("BoundAt = %v, want nil", *fs.BoundAt)
	}
}

func TestStats_TCPConnCount(t *testing.T) {
	upstreamPort := pickFreeTCPPort(t)
	upstream, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", upstreamPort))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = upstream.Close() })
	go func() {
		for {
			c, err := upstream.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_, _ = io.Copy(c, c)
			}(c)
		}
	}()

	fwdPort := pickFreeTCPPort(t)
	f, err := New(Config{
		Forwards: []Forward{{
			Proto:      ProtoTCP,
			ListenAddr: fmt.Sprintf("127.0.0.1:%d", fwdPort),
			DestAddr:   upstream.Addr().String(),
		}},
		Logger: discardLogger(),
	})
	if err != nil {
		t.Fatal(err)
	}
	_ = runForwarder(t, f)

	msg := []byte("ping")
	_ = roundTripTCP(t, fwdPort, msg, 2*time.Second)
	_ = roundTripTCP(t, fwdPort, msg, 2*time.Second)

	waitDeadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(waitDeadline) {
		if f.Stats().TCPConns == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Errorf("TCPConns = %d after conns closed, want 0", f.Stats().TCPConns)
}

func TestStats_UDPFlowCount(t *testing.T) {
	upstreamAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	upstream, err := net.ListenUDP("udp", upstreamAddr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = upstream.Close() })
	go echoUDP(upstream)

	fwdPort := pickFreeUDPPort(t)
	f, err := New(Config{
		Forwards: []Forward{{
			Proto:      ProtoUDP,
			ListenAddr: fmt.Sprintf("127.0.0.1:%d", fwdPort),
			DestAddr:   upstream.LocalAddr().String(),
		}},
		UDPFlowIdle: 100 * time.Millisecond,
		Logger:      discardLogger(),
	})
	if err != nil {
		t.Fatal(err)
	}
	_ = runForwarder(t, f)

	_ = roundTripUDP(t, fwdPort, []byte("ping"), 2*time.Second)

	waitDeadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(waitDeadline) {
		if f.Stats().UDPFlows == 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Errorf("UDPFlows = %d after idle timeout, want 0", f.Stats().UDPFlows)
}

func TestStats_ForwardsSliceIsCopy(t *testing.T) {
	upstream, _ := net.Listen("tcp", "127.0.0.1:0")
	_ = upstream.Close()
	f, err := New(Config{
		Forwards: []Forward{{Proto: ProtoTCP, ListenAddr: "127.0.0.1:0", DestAddr: upstream.Addr().String()}},
		Logger:   discardLogger(),
	})
	if err != nil {
		t.Fatal(err)
	}
	_ = runForwarder(t, f)

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(f.Stats().Forwards) > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(f.Stats().Forwards) == 0 {
		t.Fatalf("expected at least one forward after bind; stats = %+v", f.Stats())
	}

	stats := f.Stats()
	stats.Forwards[0].Bound = false
	stats.Forwards[0].LastError = "mutated by test"

	again := f.Stats()
	if !again.Forwards[0].Bound {
		t.Error("mutating Stats().Forwards affected the forwarder state; should be a copy")
	}
	if again.Forwards[0].LastError != "" {
		t.Errorf("LastError = %q, want empty (mutation leaked through)", again.Forwards[0].LastError)
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
