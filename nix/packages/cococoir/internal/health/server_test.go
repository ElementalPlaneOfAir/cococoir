// SPDX-License-Identifier: AGPL-3.0-or-later
package health

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func startTestServer(t *testing.T, status StatusFunc) *Server {
	t.Helper()
	srv := NewServer("127.0.0.1:0", status, discardLogger())
	ready := make(chan struct{})
	go func() {
		close(ready)
		_ = srv.ListenAndServe()
	}()
	<-ready
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if srv.Addr() != "" {
			return srv
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("test server did not start within 2s")
	return nil
}

type fakeStatus struct {
	Forwards []struct {
		Proto      string `json:"proto"`
		ListenAddr string `json:"listen_addr"`
		Bound      bool   `json:"bound"`
	} `json:"forwards"`
}

func TestHealthz_OK(t *testing.T) {
	srv := startTestServer(t, func() any { return fakeStatus{} })
	t.Cleanup(func() { _ = srv.Shutdown(context.Background()) })

	resp, err := http.Get("http://" + srv.Addr() + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if string(body) != "ok\n" {
		t.Errorf("body = %q, want %q", body, "ok\n")
	}
}

func TestHealthz_MethodNotAllowed(t *testing.T) {
	srv := startTestServer(t, func() any { return fakeStatus{} })
	t.Cleanup(func() { _ = srv.Shutdown(context.Background()) })

	req, _ := http.NewRequest(http.MethodPost, "http://"+srv.Addr()+"/healthz", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("status = %d, want 405", resp.StatusCode)
	}
}

func TestReadyz_NoBoundForward(t *testing.T) {
	srv := startTestServer(t, func() any { return fakeStatus{} })
	t.Cleanup(func() { _ = srv.Shutdown(context.Background()) })

	resp, err := http.Get("http://" + srv.Addr() + "/readyz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", resp.StatusCode)
	}
}

func TestReadyz_OneBoundForward(t *testing.T) {
	status := fakeStatus{}
	status.Forwards = append(status.Forwards, struct {
		Proto      string `json:"proto"`
		ListenAddr string `json:"listen_addr"`
		Bound      bool   `json:"bound"`
	}{Proto: "tcp", ListenAddr: "1.2.3.4:80", Bound: true})

	srv := startTestServer(t, func() any { return status })
	t.Cleanup(func() { _ = srv.Shutdown(context.Background()) })

	resp, err := http.Get("http://" + srv.Addr() + "/readyz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), `"ready":true`) {
		t.Errorf("body = %q, want ready:true", body)
	}
}

func TestStatus_ReturnsJSON(t *testing.T) {
	type myStatus struct {
		Component string `json:"component"`
		Forwards  []struct {
			Bound bool `json:"bound"`
		} `json:"forwards"`
	}
	want := myStatus{Component: "cococoir-test"}
	want.Forwards = append(want.Forwards, struct {
		Bound bool `json:"bound"`
	}{Bound: true})

	srv := startTestServer(t, func() any { return want })
	t.Cleanup(func() { _ = srv.Shutdown(context.Background()) })

	resp, err := http.Get("http://" + srv.Addr() + "/status")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	var got myStatus
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Component != "cococoir-test" {
		t.Errorf("Component = %q, want cococoir-test", got.Component)
	}
	if len(got.Forwards) != 1 || !got.Forwards[0].Bound {
		t.Errorf("Forwards = %+v, want one bound forward", got.Forwards)
	}
}

func TestStatus_NoStatusFunc(t *testing.T) {
	srv := NewServer("127.0.0.1:0", nil, discardLogger())
	ready := make(chan struct{})
	go func() {
		close(ready)
		_ = srv.ListenAndServe()
	}()
	<-ready
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if srv.Addr() != "" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Cleanup(func() { _ = srv.Shutdown(context.Background()) })

	resp, err := http.Get("http://" + srv.Addr() + "/status")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", resp.StatusCode)
	}
}

func TestNewServer_EmptyAddrIsNoop(t *testing.T) {
	srv := NewServer("", func() any { return nil }, discardLogger())
	if err := srv.ListenAndServe(); err != nil {
		t.Errorf("ListenAndServe with empty addr: got %v, want nil", err)
	}
	if err := srv.Shutdown(context.Background()); err != nil {
		t.Errorf("Shutdown with empty addr: got %v, want nil", err)
	}
}

func TestListenAndServe_PortInUse(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	srv := NewServer(ln.Addr().String(), func() any { return nil }, discardLogger())
	err = srv.ListenAndServe()
	if err == nil {
		t.Fatal("ListenAndServe on in-use port: got nil error, want one")
	}
}

func TestShutdown_StopsServer(t *testing.T) {
	srv := startTestServer(t, func() any { return fakeStatus{} })
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}

	resp, err := http.Get("http://" + srv.Addr() + "/healthz")
	if err == nil {
		resp.Body.Close()
		t.Error("expected error after Shutdown, got success")
	}
}
