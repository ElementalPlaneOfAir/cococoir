// SPDX-License-Identifier: AGPL-3.0-or-later
// Package store is the bbolt-backed key/value store used by the
// cococoir-edge binary. One file per VPS at /var/lib/cococoir/edge.db.
// Buckets are top-level namespaces; values are arbitrary bytes
// (callers typically JSON-marshal structured records). A typed
// layer on top of the generic Get/Put/Delete/List handles the
// records cococoir actually stores today (Customer, see
// customer.go). Future records (Event, Server, etc.) get their
// own typed layer in the same package — same bbolt file, more
// buckets. See PLAN_2.md ADR-019.
package store

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	bolt "go.etcd.io/bbolt"
)

// ErrNotFound is returned by Get when the key is absent, and by
// GetXxx typed helpers that wrap Get.
var ErrNotFound = errors.New("store: not found")

// DefaultFileMode is the file mode applied to a freshly-opened
// database. 0o600 because the database may carry per-customer
// records (admin URL, server IDs) that are sensitive within the
// cluster.
const DefaultFileMode = 0o600

// Bucket names. Adding a new record type means adding a new
// constant here and using it in the typed layer; do not pass
// arbitrary strings into Put/Get.
const (
	BucketCustomers = "customers"
)

// Store wraps a bbolt database. Construct with Open, release with
// Close. Safe for concurrent use; bbolt serialises writes and
// allows concurrent reads internally.
type Store struct {
	db *bolt.DB
}

// Open opens (or creates) a bbolt database at path. The parent
// directory is created if it does not exist. The caller must call
// Close. All known buckets are created if they do not exist.
//
// The 5s bbolt Open timeout is a defensive default: a wedged flock
// from a previous crash is the most common cause of an open that
// blocks indefinitely.
func Open(path string) (*Store, error) {
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("store: mkdir %q: %w", dir, err)
		}
	}
	db, err := bolt.Open(path, DefaultFileMode, &bolt.Options{Timeout: 5 * time.Second})
	if err != nil {
		return nil, fmt.Errorf("store: open %q: %w", path, err)
	}
	if err := db.Update(func(tx *bolt.Tx) error {
		for _, name := range []string{BucketCustomers} {
			if _, err := tx.CreateBucketIfNotExists([]byte(name)); err != nil {
				return fmt.Errorf("store: create bucket %q: %w", name, err)
			}
		}
		return nil
	}); err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

// Close releases the underlying bbolt file lock. Subsequent
// operations on the Store return an error.
func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

// Get returns the value stored at (bucket, key), or ErrNotFound if
// either the bucket or the key is absent. The returned slice is a
// copy safe to retain past the call.
func (s *Store) Get(bucket, key []byte) ([]byte, error) {
	var value []byte
	err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucket)
		if b == nil {
			return ErrNotFound
		}
		v := b.Get(key)
		if v == nil {
			return ErrNotFound
		}
		value = append(value, v...)
		return nil
	})
	return value, err
}

// Put stores value at (bucket, key), creating the bucket if it
// does not exist (a future bucket constant added to Open is the
// supported path; this is a safety net).
func (s *Store) Put(bucket, key, value []byte) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists(bucket)
		if err != nil {
			return fmt.Errorf("store: bucket %q: %w", bucket, err)
		}
		return b.Put(key, value)
	})
}

// Delete removes the entry at (bucket, key). Deleting an absent
// key is a no-op; deleting from an absent bucket is a no-op.
func (s *Store) Delete(bucket, key []byte) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucket)
		if b == nil {
			return nil
		}
		return b.Delete(key)
	})
}

// List returns a copy of every key in bucket, in bbolt's natural
// (sorted-by-key) order. Empty slice if the bucket is absent.
// The returned slices are independent copies; mutating them does
// not affect the database.
func (s *Store) List(bucket []byte) ([][]byte, error) {
	var keys [][]byte
	err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucket)
		if b == nil {
			return nil
		}
		return b.ForEach(func(k, _ []byte) error {
			keys = append(keys, append([]byte(nil), k...))
			return nil
		})
	})
	return keys, err
}

// equalBytes is a small helper kept here so tests and the typed
// layer do not have to import bytes for the common
// "compare two []byte" check.
func equalBytes(a, b []byte) bool {
	return bytes.Equal(a, b)
}
