// SPDX-License-Identifier: AGPL-3.0-or-later
package forwarder

import (
	"context"
	"errors"
	"fmt"
	"net"
	"syscall"
	"time"
)

const (
	retryBackoffStart = 100 * time.Millisecond
	retryBackoffMax   = 5 * time.Second
)

func retryListen(ctx context.Context, totalTimeout time.Duration, network, addr string) (net.Listener, error) {
	deadline := time.Now().Add(totalTimeout)
	delay := retryBackoffStart
	for attempt := 1; ; attempt++ {
		ln, err := net.Listen(network, addr)
		if err == nil {
			return ln, nil
		}
		if !isTransientBindErr(err) {
			return nil, fmt.Errorf("listen %s %s: %w", network, addr, err)
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("listen %s %s: gave up after %v (%d attempts): %w", network, addr, totalTimeout, attempt, err)
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		delay = nextBackoff(delay)
	}
}

func retryListenPacket(ctx context.Context, totalTimeout time.Duration, network, addr string) (*net.UDPConn, error) {
	deadline := time.Now().Add(totalTimeout)
	delay := retryBackoffStart
	for attempt := 1; ; attempt++ {
		pc, err := net.ListenPacket(network, addr)
		if err == nil {
			uc, ok := pc.(*net.UDPConn)
			if !ok {
				_ = pc.Close()
				return nil, fmt.Errorf("listen %s %s: expected *net.UDPConn, got %T", network, addr, pc)
			}
			return uc, nil
		}
		if !isTransientBindErr(err) {
			return nil, fmt.Errorf("listen %s %s: %w", network, addr, err)
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("listen %s %s: gave up after %v (%d attempts): %w", network, addr, totalTimeout, attempt, err)
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		delay = nextBackoff(delay)
	}
}

func nextBackoff(d time.Duration) time.Duration {
	d *= 2
	if d > retryBackoffMax {
		return retryBackoffMax
	}
	return d
}

func isTransientBindErr(err error) bool {
	return err != nil && (errors.Is(err, syscall.EADDRNOTAVAIL) ||
		errors.Is(err, syscall.ENETDOWN) ||
		errors.Is(err, syscall.ENETUNREACH))
}
