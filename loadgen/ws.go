package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"io"
	"net"
	"time"
)

// runWS performs an RFC 6455 handshake and reads frames until the connection breaks.
//
// Hand-rolled for the same reason as the SSE side, and one more: gorilla/websocket and
// coder/websocket both keep a read AND a write buffer per connection (4 KB each by
// default). That is ~8 KB of client memory per connection spent on a channel this
// client uses only to answer pings — and at 50,000 connections the load generator's
// own memory is the thing that decides whether the measurement is possible.
func runWS(conn net.Conn, path string, host string, idx int, m *metrics, handshake time.Duration) {
	defer conn.Close()

	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		m.connFailed.Add(1)
		m.note("ws nonce: " + err.Error())
		return
	}
	key := base64.StdEncoding.EncodeToString(nonce[:])

	req := "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUpgrade: websocket\r\n" +
		"Connection: Upgrade\r\nSec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		m.connFailed.Add(1)
		m.note("ws write handshake: " + err.Error())
		return
	}

	// Handshake only — see the note in runSSE. Cleared before the first frame is read.
	_ = conn.SetReadDeadline(time.Now().Add(handshake))

	r := bufio.NewReaderSize(conn, 4096)
	status, err := r.ReadString('\n')
	if err != nil {
		if isTimeout(err) {
			m.connStalled.Add(1)
			m.note("ws stalled: connected, never upgraded")
		} else {
			m.connFailed.Add(1)
			m.note("ws read status: " + err.Error())
		}
		return
	}
	// 101 is the only success. Anything else — 503 at the admission cap, 429, 500 — is a
	// refusal the report must distinguish from a socket that never opened.
	if len(status) < 12 || status[9:12] != "101" {
		m.connRejected.Add(1)
		m.note("ws status: " + trimCRLF(status))
		return
	}
	// The Sec-WebSocket-Accept digest is deliberately not verified: this client talks to one
	// server it started itself, and the SHA-1 would be per connection on the ramp's hot path.
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			m.connFailed.Add(1)
			m.note("ws read headers: " + err.Error())
			return
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}

	_ = conn.SetReadDeadline(time.Time{})
	m.established.Add(1)
	defer m.dropped.Add(1)

	// 512, not 8192. The frames under test are 265 bytes and the buffer grows if one is larger —
	// at 20,000 connections per container an 8 KB buffer each is 160 MB of client memory spent on
	// headroom that is never used, and client memory is what decides how many connections a single
	// load generator can hold.
	payload := make([]byte, 512)
	first := true
	for {
		var head [2]byte
		if _, err := io.ReadFull(r, head[:]); err != nil {
			if !m.stopping() {
				m.note("ws read header: " + err.Error())
			}
			return
		}
		opcode := head[0] & 0x0f
		masked := head[1]&0x80 != 0
		length := int64(head[1] & 0x7f)

		switch length {
		case 126:
			var ext [2]byte
			if _, err := io.ReadFull(r, ext[:]); err != nil {
				return
			}
			length = int64(binary.BigEndian.Uint16(ext[:]))
		case 127:
			var ext [8]byte
			if _, err := io.ReadFull(r, ext[:]); err != nil {
				return
			}
			length = int64(binary.BigEndian.Uint64(ext[:]))
		}
		frameBytes := 2 + length
		if masked {
			// A server MUST NOT mask. Reading the key anyway keeps the parser honest rather
			// than silently misaligning every frame after it.
			var maskKey [4]byte
			if _, err := io.ReadFull(r, maskKey[:]); err != nil {
				return
			}
			frameBytes += 4
		}
		if length > int64(len(payload)) {
			payload = make([]byte, length)
		}
		body := payload[:length]
		if _, err := io.ReadFull(r, body); err != nil {
			if !m.stopping() {
				m.note("ws read payload: " + err.Error())
			}
			return
		}
		m.bytesIn.Add(frameBytes)

		switch opcode {
		case 0x1, 0x2: // text, binary — both carry the same JSON
			if first {
				m.firstFrame.Add(1)
				first = false
			}
			m.frames.Add(1)
			if ts := extractTS(body); ts > 0 {
				m.lat.record(idx, time.Now().UnixMicro()-ts)
			} else {
				m.malformed.Add(1)
			}
		case 0x9: // ping — a pong is mandatory, and skipping it makes the server close us mid-run
			if err := writePong(conn, body); err != nil {
				return
			}
		case 0x8: // close
			return
		}
	}
}

// writePong answers a ping. Client-to-server frames MUST be masked (RFC 6455 §5.3);
// an unmasked one is a protocol error and Tomcat closes the connection on it.
func writePong(conn net.Conn, body []byte) error {
	n := len(body)
	if n > 125 {
		n = 125
	}
	buf := make([]byte, 0, 6+n)
	buf = append(buf, 0x8a, byte(0x80|n))
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return err
	}
	buf = append(buf, mask[:]...)
	for i := 0; i < n; i++ {
		buf = append(buf, body[i]^mask[i&3])
	}
	_, err := conn.Write(buf)
	return err
}
