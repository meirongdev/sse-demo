package main

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"time"
)

// runSSE opens one text/event-stream and reads it until it breaks.
//
// Hand-rolled rather than net/http, and that is a measurement decision, not a style one.
// http.Client keeps a Transport, a Request, a Response and two buffered readers per
// connection — on the order of 30-40 KB — so at 50,000 connections the LOAD GENERATOR
// would hit its own memory wall first and the run would report the client's ceiling as
// the server's. Raw net.Conn plus one small bufio.Reader is ~6 KB per connection.
func runSSE(conn net.Conn, path string, host string, idx int, m *metrics, handshake time.Duration) {
	defer conn.Close()

	req := "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nAccept: text/event-stream\r\n" +
		"Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		m.connFailed.Add(1)
		m.note("sse write request: " + err.Error())
		return
	}

	// The deadline covers the HANDSHAKE ONLY and is cleared before the stream is read. A stream is
	// idle by design between ticks, so a deadline left in place would close every healthy connection.
	_ = conn.SetReadDeadline(time.Now().Add(handshake))

	r := bufio.NewReaderSize(conn, 4096)

	// Status line and headers. A 503 here is the server's admission cap and is a RESULT,
	// not an error — it is the difference between "refused" and "accepted then dropped".
	status, err := r.ReadString('\n')
	if err != nil {
		if isTimeout(err) {
			m.connStalled.Add(1)
			m.note("sse stalled: connected, never served")
		} else {
			m.connFailed.Add(1)
			m.note("sse read status: " + err.Error())
		}
		return
	}
	if len(status) < 12 || status[9:12] != "200" {
		m.connRejected.Add(1)
		m.note("sse status: " + trimCRLF(status))
		return
	}
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			m.connFailed.Add(1)
			m.note("sse read headers: " + err.Error())
			return
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}

	_ = conn.SetReadDeadline(time.Time{})
	m.established.Add(1)
	defer m.dropped.Add(1)

	first := true
	for {
		// ReadSlice returns a view into the reader's own buffer: no allocation per frame,
		// which at 50,000 frames a second is the difference between a quiet client and one
		// whose GC shows up in the latency it is trying to measure.
		line, err := r.ReadSlice('\n')
		if err != nil {
			if !m.stopping() {
				m.note("sse read: " + err.Error())
			}
			return
		}
		m.bytesIn.Add(int64(len(line)))
		// ⚠ Spring writes `data:` with NO space after the colon. The space is optional in the SSE
		// grammar and a browser's EventSource strips it if present, so both spellings are valid and
		// a client that expects one of them silently counts zero frames against the other — which is
		// exactly what the first smoke run did, while the byte counter showed traffic flowing.
		if len(line) < 6 || string(line[:5]) != "data:" {
			continue // a `:ping` comment, a chunk-size line, or the blank line that ends an event
		}
		if first {
			m.firstFrame.Add(1)
			first = false
		}
		m.frames.Add(1)
		if ts := extractTS(line); ts > 0 {
			m.lat.record(idx, time.Now().UnixMicro()-ts)
		} else {
			m.malformed.Add(1)
		}
	}
}

func trimCRLF(s string) string {
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == '\r') {
		s = s[:len(s)-1]
	}
	return s
}

// extractTS pulls the server's compose timestamp out without decoding the JSON.
// encoding/json on 50,000 frames a second would allocate a map per frame and the
// client's own GC pauses would land in the latency histogram.
func extractTS(b []byte) int64 {
	const key = `"ts":`
	i := indexBytes(b, key)
	if i < 0 {
		return -1
	}
	i += len(key)
	var v int64
	seen := false
	for ; i < len(b) && b[i] >= '0' && b[i] <= '9'; i++ {
		v = v*10 + int64(b[i]-'0')
		seen = true
	}
	if !seen {
		return -1
	}
	return v
}

func indexBytes(b []byte, sub string) int {
	n := len(sub)
	if n == 0 || len(b) < n {
		return -1
	}
	for i := 0; i+n <= len(b); i++ {
		if b[i] == sub[0] && string(b[i:i+n]) == sub {
			return i
		}
	}
	return -1
}

func isTimeout(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

var _ = fmt.Sprintf
