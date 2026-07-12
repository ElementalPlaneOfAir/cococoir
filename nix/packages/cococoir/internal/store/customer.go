// SPDX-License-Identifier: AGPL-3.0-or-later
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Customer is the per-customer record kept in the BucketCustomers
// bucket. One record per customer, keyed by Name. A customer is
// the unit of provisioning in cococoir: it has a domain, an
// allocated public IPv4 (Hetzner), a VPS that the customer lives
// on, and the time the record was first written.
//
// All fields are JSON-serialised; the on-disk format is the
// natural Go JSON layout, with omitempty so a freshly-minted
// record round-trips cleanly. Domain and PublicIP are required
// for a "real" record (provisioning assumes both are set); Name
// is the primary key and is required by PutCustomer.
type Customer struct {
	Name      string    `json:"name"`
	Domain    string    `json:"domain"`
	PublicIP  string    `json:"public_ip,omitempty"`
	VPSName   string    `json:"vps_name,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// GetCustomer returns the customer named name, or ErrNotFound.
// A malformed record (valid JSON in the slot but failing to
// unmarshal into Customer) is returned as a wrapped error; the
// caller can decide whether to delete the corrupt record or
// surface it.
func (s *Store) GetCustomer(name string) (*Customer, error) {
	data, err := s.Get([]byte(BucketCustomers), []byte(name))
	if err != nil {
		return nil, err
	}
	var c Customer
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("store: unmarshal customer %q: %w", name, err)
	}
	return &c, nil
}

// PutCustomer writes c to the store. Name is the primary key and
// must be non-empty. A record with a zero CreatedAt gets the
// current time, so callers can omit it on first write.
func (s *Store) PutCustomer(c Customer) error {
	if c.Name == "" {
		return errors.New("store: customer name is required")
	}
	if c.CreatedAt.IsZero() {
		c.CreatedAt = time.Now().UTC()
	}
	data, err := json.Marshal(c)
	if err != nil {
		return fmt.Errorf("store: marshal customer %q: %w", c.Name, err)
	}
	return s.Put([]byte(BucketCustomers), []byte(c.Name), data)
}

// DeleteCustomer removes the customer named name. Deleting an
// absent customer is a no-op.
func (s *Store) DeleteCustomer(name string) error {
	return s.Delete([]byte(BucketCustomers), []byte(name))
}

// ListCustomers returns every customer record in the store, in
// key-sorted order. A record that fails to unmarshal is skipped
// and reported via the second return value; the first return
// value still contains every well-formed record. This keeps
// transient corruption (e.g. an interrupted write that left a
// half-record on disk) from blocking the operator from seeing
// the rest of the data.
func (s *Store) ListCustomers() ([]Customer, error) {
	keys, err := s.List([]byte(BucketCustomers))
	if err != nil {
		return nil, err
	}
	out := make([]Customer, 0, len(keys))
	for _, k := range keys {
		c, err := s.GetCustomer(string(k))
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				continue
			}
			return out, err
		}
		out = append(out, *c)
	}
	return out, nil
}
