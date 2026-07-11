// SPDX-License-Identifier: AGPL-3.0-or-later
package logger

import "testing"

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
