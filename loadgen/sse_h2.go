package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"time"

	"golang.org/x/net/http2"
)

// newH2Transport builds an h2c (cleartext HTTP/2) transport.
//
// AllowHTTP with a DialTLSContext that does a PLAIN TCP dial is the documented way to speak h2c with
// x/net/http2: the transport skips the TLS handshake and sends the HTTP/2 connection preface directly.
// No TLS, deliberately — TLS is a separate untested axis, and bundling it in would leave an h2-vs-h1
// difference that could be either one.
func newH2Transport() *http2.Transport {
	return &http2.Transport{
		AllowHTTP: true,
		DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
			return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, network, addr)
		},
		// Off, so one TCP connection carries as many streams as the server's SETTINGS allow. Left on,
		// the transport would open a second connection at the first sign of contention and the run would
		// silently measure less multiplexing than it reports.
		StrictMaxConcurrentStreams: false,
		ReadIdleTimeout:            0,
		PingTimeout:                0,
	}
}

// runSSEH2 opens one SSE stream over a shared h2 connection and reads it until it breaks.
//
// ⚠ Unlike the HTTP/1.1 path this uses net/http rather than a hand-rolled parser, because HPACK, the
// frame layer and flow control are not worth reimplementing. That costs client memory per stream, which
// is why the h2 runs give the client container more of it — the SERVER is what is being measured.
func runSSEH2(tr *http2.Transport, url string, idx int, m *metrics, handshake time.Duration) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		m.connFailed.Add(1)
		m.note("h2 build request: " + err.Error())
		return
	}
	req.Header.Set("Accept", "text/event-stream")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	timer := time.AfterFunc(handshake, cancel)
	resp, err := tr.RoundTrip(req.WithContext(ctx))
	timer.Stop()
	if err != nil {
		if ctx.Err() != nil {
			m.connStalled.Add(1)
			m.note("h2 stalled: stream opened, never served")
		} else {
			m.connFailed.Add(1)
			m.note("h2 roundtrip: " + err.Error())
		}
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		m.connRejected.Add(1)
		m.note("h2 status: " + resp.Status)
		return
	}

	m.established.Add(1)
	defer m.dropped.Add(1)

	r := bufio.NewReaderSize(resp.Body, 4096)
	first := true
	for {
		line, err := r.ReadSlice('\n')
		if err != nil {
			if !m.stopping() {
				m.note("h2 read: " + err.Error())
			}
			return
		}
		m.bytesIn.Add(int64(len(line)))
		// No chunked framing on h2 — the transport delivers DATA frame payloads, so what arrives here is
		// the SSE body and nothing else.
		if len(line) < 6 || string(line[:5]) != "data:" {
			continue
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
