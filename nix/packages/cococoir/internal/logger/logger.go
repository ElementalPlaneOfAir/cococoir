// SPDX-License-Identifier: AGPL-3.0-or-later
// Package logger builds the structured *slog.Logger used by the
// cococoir binaries. The cmd entry points (cmd/edge, cmd/client)
// call ParseFormat on their -log-format flag, then call Build on
// the resulting Format with os.Stderr. The same data model
// (component, msg, structured key/value attrs) is emitted whether
// the handler is text or JSON, so a future telemetry pipeline can
// ingest the JSON form without needing to re-parse human-readable
// text.
package logger

import (
	"fmt"
	"io"
	"log/slog"
)

// Format is the structured-logging output format. Use the FormatText
// and FormatJSON constants directly, or obtain a Format from
// ParseFormat after parsing an operator-supplied string.
type Format string

const (
	FormatText Format = "text"
	FormatJSON Format = "json"
)

// ParseFormat returns the Format for s, or an error if s is not
// one of the known formats. cmd entry points call this on their
// -log-format flag value.
func ParseFormat(s string) (Format, error) {
	switch Format(s) {
	case FormatText, FormatJSON:
		return Format(s), nil
	default:
		return "", fmt.Errorf("logger: unknown format %q (want %q or %q)", s, FormatText, FormatJSON)
	}
}

// Build returns a *slog.Logger writing to w in f's format at Info
// level, with a "component" attribute attached to every record.
// Callers must obtain Format from ParseFormat; an unknown Format
// is a programmer error and panics. The cmd entry points validate
// via ParseFormat and os.Exit(1) on failure, so this panic is
// unreachable in production.
func (f Format) Build(w io.Writer, component string) *slog.Logger {
	opts := &slog.HandlerOptions{Level: slog.LevelInfo}
	var handler slog.Handler
	switch f {
	case FormatJSON:
		handler = slog.NewJSONHandler(w, opts)
	case FormatText:
		handler = slog.NewTextHandler(w, opts)
	default:
		panic(fmt.Sprintf("logger: unknown format %q, add a case in Build", string(f)))
	}
	return slog.New(handler).With("component", component)
}
