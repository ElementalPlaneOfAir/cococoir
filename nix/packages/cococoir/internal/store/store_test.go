// SPDX-License-Identifier: AGPL-3.0-or-later
package store

import (
	"errors"
	"path/filepath"
	"testing"
)

func tempStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	s, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestOpen_Close(t *testing.T) {
	s := tempStore(t)
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
}

func TestGet_AbsentBucket(t *testing.T) {
	s := tempStore(t)
	_, err := s.Get([]byte("does-not-exist"), []byte("k"))
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("Get on absent bucket: got %v, want ErrNotFound", err)
	}
}

func TestGet_AbsentKey(t *testing.T) {
	s := tempStore(t)
	_, err := s.Get([]byte(BucketCustomers), []byte("missing"))
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("Get on absent key: got %v, want ErrNotFound", err)
	}
}

func TestPut_Get_RoundTrip(t *testing.T) {
	s := tempStore(t)
	want := []byte("hello, bbolt")
	if err := s.Put([]byte(BucketCustomers), []byte("greeting"), want); err != nil {
		t.Fatalf("Put: %v", err)
	}
	got, err := s.Get([]byte(BucketCustomers), []byte("greeting"))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !equalBytes(got, want) {
		t.Errorf("Get = %q, want %q", got, want)
	}
}

func TestPut_Overwrite(t *testing.T) {
	s := tempStore(t)
	_ = s.Put([]byte(BucketCustomers), []byte("k"), []byte("first"))
	if err := s.Put([]byte(BucketCustomers), []byte("k"), []byte("second")); err != nil {
		t.Fatalf("Put overwrite: %v", err)
	}
	got, err := s.Get([]byte(BucketCustomers), []byte("k"))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(got) != "second" {
		t.Errorf("after overwrite, got %q, want %q", got, "second")
	}
}

func TestDelete(t *testing.T) {
	s := tempStore(t)
	_ = s.Put([]byte(BucketCustomers), []byte("k"), []byte("v"))
	if err := s.Delete([]byte(BucketCustomers), []byte("k")); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	_, err := s.Get([]byte(BucketCustomers), []byte("k"))
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("after Delete: got %v, want ErrNotFound", err)
	}
}

func TestDelete_AbsentIsNoop(t *testing.T) {
	s := tempStore(t)
	if err := s.Delete([]byte(BucketCustomers), []byte("never-existed")); err != nil {
		t.Errorf("Delete absent key: got %v, want nil", err)
	}
	if err := s.Delete([]byte("absent-bucket"), []byte("k")); err != nil {
		t.Errorf("Delete absent bucket: got %v, want nil", err)
	}
}

func TestList_Sorted(t *testing.T) {
	s := tempStore(t)
	for _, k := range []string{"charlie", "alpha", "bravo"} {
		_ = s.Put([]byte(BucketCustomers), []byte(k), []byte("v"))
	}
	keys, err := s.List([]byte(BucketCustomers))
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	got := keysToStrings(keys)
	want := []string{"alpha", "bravo", "charlie"}
	if len(got) != len(want) {
		t.Fatalf("List returned %d keys, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("List[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestList_AbsentBucketEmpty(t *testing.T) {
	s := tempStore(t)
	keys, err := s.List([]byte("does-not-exist"))
	if err != nil {
		t.Errorf("List on absent bucket: got %v, want nil", err)
	}
	if len(keys) != 0 {
		t.Errorf("List on absent bucket: got %d keys, want 0", len(keys))
	}
}

func TestCustomer_PutRequiresName(t *testing.T) {
	s := tempStore(t)
	if err := s.PutCustomer(Customer{Domain: "x.test"}); err == nil {
		t.Fatal("PutCustomer with empty Name: expected error, got nil")
	}
}

func TestCustomer_RoundTrip(t *testing.T) {
	s := tempStore(t)
	in := Customer{
		Name:     "alice",
		Domain:   "alice.example.com",
		PublicIP: "1.2.3.4",
		VPSName:  "vps-1",
	}
	if err := s.PutCustomer(in); err != nil {
		t.Fatalf("PutCustomer: %v", err)
	}
	out, err := s.GetCustomer("alice")
	if err != nil {
		t.Fatalf("GetCustomer: %v", err)
	}
	if out.Name != in.Name || out.Domain != in.Domain || out.PublicIP != in.PublicIP || out.VPSName != in.VPSName {
		t.Errorf("round-trip: got %+v, want %+v", out, in)
	}
	if out.CreatedAt.IsZero() {
		t.Errorf("round-trip: CreatedAt is zero, want auto-set")
	}
}

func TestCustomer_GetAbsent(t *testing.T) {
	s := tempStore(t)
	_, err := s.GetCustomer("nobody")
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("GetCustomer absent: got %v, want ErrNotFound", err)
	}
}

func TestCustomer_OverwritePreservesCreatedAt(t *testing.T) {
	s := tempStore(t)
	first := Customer{Name: "alice", Domain: "alice.test"}
	if err := s.PutCustomer(first); err != nil {
		t.Fatal(err)
	}
	original, err := s.GetCustomer("alice")
	if err != nil {
		t.Fatal(err)
	}
	original.PublicIP = "5.6.7.8"
	if err := s.PutCustomer(*original); err != nil {
		t.Fatal(err)
	}
	updated, err := s.GetCustomer("alice")
	if err != nil {
		t.Fatal(err)
	}
	if !updated.CreatedAt.Equal(original.CreatedAt) {
		t.Errorf("CreatedAt changed across overwrite: was %v, now %v", original.CreatedAt, updated.CreatedAt)
	}
	if updated.PublicIP != "5.6.7.8" {
		t.Errorf("PublicIP = %q, want %q", updated.PublicIP, "5.6.7.8")
	}
}

func TestCustomer_DeleteAndList(t *testing.T) {
	s := tempStore(t)
	_ = s.PutCustomer(Customer{Name: "alice", Domain: "a.test"})
	_ = s.PutCustomer(Customer{Name: "bob", Domain: "b.test"})
	_ = s.PutCustomer(Customer{Name: "carol", Domain: "c.test"})

	customers, err := s.ListCustomers()
	if err != nil {
		t.Fatalf("ListCustomers: %v", err)
	}
	if len(customers) != 3 {
		t.Fatalf("ListCustomers: got %d, want 3", len(customers))
	}

	if err := s.DeleteCustomer("bob"); err != nil {
		t.Fatalf("DeleteCustomer: %v", err)
	}
	customers, err = s.ListCustomers()
	if err != nil {
		t.Fatalf("ListCustomers after delete: %v", err)
	}
	if len(customers) != 2 {
		t.Errorf("after delete: got %d, want 2", len(customers))
	}
	for _, c := range customers {
		if c.Name == "bob" {
			t.Errorf("after delete: bob still in list (%+v)", c)
		}
	}
}

func TestReopen_PersistsData(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "reopen.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutCustomer(Customer{Name: "alice", Domain: "a.test"}); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	s2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer s2.Close()
	c, err := s2.GetCustomer("alice")
	if err != nil {
		t.Fatalf("GetCustomer after reopen: %v", err)
	}
	if c.Domain != "a.test" {
		t.Errorf("after reopen: Domain = %q, want %q", c.Domain, "a.test")
	}
}

func keysToStrings(keys [][]byte) []string {
	out := make([]string, len(keys))
	for i, k := range keys {
		out[i] = string(k)
	}
	return out
}
