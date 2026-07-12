// SPDX-License-Identifier: AGPL-3.0-or-later
package logger

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestParseFormat(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		want    Format
		wantErr bool
	}{
		{"text", "text", FormatText, false},
		{"json", "json", FormatJSON, false},
		{"xml", "xml", "", true},
		{"empty", "", "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := ParseFormat(c.in)
			if (err != nil) != c.wantErr {
				t.Fatalf("ParseFormat(%q) err = %v, wantErr = %v", c.in, err, c.wantErr)
			}
			if got != c.want {
				t.Errorf("ParseFormat(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestBuild_JSON_AttachesComponent(t *testing.T) {
	var buf bytes.Buffer
	lg := FormatJSON.Build(&buf, "cococoir-edge")
	lg.Info("test message", "key", "value")

	var rec map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &rec); err != nil {
		t.Fatalf("unmarshal log record: %v\nraw: %s", err, buf.String())
	}
	if rec["component"] != "cococoir-edge" {
		t.Errorf("component = %v, want %q", rec["component"], "cococoir-edge")
	}
	if rec["msg"] != "test message" {
		t.Errorf("msg = %v, want %q", rec["msg"], "test message")
	}
	if rec["key"] != "value" {
		t.Errorf("key = %v, want %q", rec["key"], "value")
	}
}

func TestBuild_Text_AttachesComponent(t *testing.T) {
	var buf bytes.Buffer
	lg := FormatText.Build(&buf, "cococoir-client")
	lg.Info("hello")

	line := buf.String()
	if !strings.Contains(line, "component=cococoir-client") {
		t.Errorf("text log missing component attr: %q", line)
	}
	if !strings.Contains(line, "msg=hello") {
		t.Errorf("text log missing msg=hello: %q", line)
	}
}

func TestBuild_UnknownFormatPanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("Build with unknown Format: expected panic, got none")
		}
	}()
	Format("xml").Build(&bytes.Buffer{}, "cococoir-edge")
}
