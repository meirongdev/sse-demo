package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/http2"
)

type metrics struct {
	dialed      atomic.Int64
	established atomic.Int64
	firstFrame  atomic.Int64
	connFailed  atomic.Int64
	connRejected atomic.Int64
	// ⚠ THE SIGNATURE OF THE maxConnections WALL, and it is silent. Past Tomcat's limit the kernel
	// still completes the three-way handshake out of the accept backlog, so dial() SUCCEEDS — and
	// then nothing ever answers. No error, no refusal, no log line on either side. Without this
	// counter those connections are simply absent from the report, and 12,000 requested against
	// 8,192 served reads as "no failures".
	connStalled atomic.Int64
	dropped     atomic.Int64
	frames      atomic.Int64
	bytesIn     atomic.Int64
	malformed   atomic.Int64
	stop        atomic.Bool
	lat         hist

	mu    sync.Mutex
	notes map[string]int
}

func newMetrics() *metrics { return &metrics{notes: map[string]int{}} }

// note keeps a COUNT per distinct error text rather than a log line per failure. At the
// ceiling every connection fails at once, and a client that logs each one spends the run
// writing to stderr instead of holding connections.
func (m *metrics) note(s string) {
	if len(s) > 120 {
		s = s[:120]
	}
	m.mu.Lock()
	if len(m.notes) < 40 {
		m.notes[s]++
	} else if _, ok := m.notes[s]; ok {
		m.notes[s]++
	}
	m.mu.Unlock()
}

func (m *metrics) stopping() bool { return m.stop.Load() }

func (m *metrics) noteSnapshot() map[string]int {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string]int, len(m.notes))
	for k, v := range m.notes {
		out[k] = v
	}
	return out
}

func main() {
	var (
		target = flag.String("target", "127.0.0.1:8080", "server host:port")
		hshake = flag.Duration("handshake-timeout", 20*time.Second, "how long to wait for the response before calling a connection stalled")
		mode   = flag.String("mode", "sse", "sse | ws | sse-h2")
		conns  = flag.Int("conns", 10000, "connections this instance opens")
		rate   = flag.Int("rate", 1000, "connections per second during the ramp")
		hold   = flag.Duration("hold", 60*time.Second, "how long to hold at full count after the ramp")
		rooms  = flag.Int("rooms", 1, "rooms to spread connections across")
		out    = flag.String("out", "", "write the summary JSON here")
		id     = flag.String("id", "0", "instance id, for the summary")
		rcvbuf = flag.Int("rcvbuf", 4096, "SO_RCVBUF per connection; 0 leaves the kernel default")
		spc    = flag.Int("streams-per-conn", 1, "sse-h2 only: SSE streams each TCP connection carries")
	)
	flag.Parse()

	host, _, err := net.SplitHostPort(*target)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bad -target:", err)
		os.Exit(2)
	}
	path := "/sse/stream"
	if *mode == "ws" {
		path = "/ws/stream"
	}
	// ⚠ ONE TRANSPORT PER SIMULATED CLIENT, not one for the whole run.
	//
	// Go's http2.Transport pools connections by host:port, so a single shared transport puts every
	// stream on ONE TCP connection — which models one client opening N streams, not N clients opening
	// one each. The first version of this harness did exactly that and measured h2's multiplexing upper
	// bound while appearing to measure production traffic.
	//
	// A real population is many clients with their own connections: a browser opens one h2 connection
	// per origin and shares it across that user's tabs, so the realistic ratio is 1 to a handful of
	// streams per connection, not tens of thousands. -streams-per-conn sets it, and 1 is the default
	// because "every client is independent" is the honest baseline.
	var transports []*http2.Transport
	if *mode == "sse-h2" {
		n := (*conns + *spc - 1) / *spc
		transports = make([]*http2.Transport, n)
		for i := range transports {
			transports[i] = newH2Transport()
		}
	}

	m := newMetrics()
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var wg sync.WaitGroup

	startedAt := time.Now()
	go report(m, startedAt)

	// The ramp. Connections are opened at a fixed rate rather than all at once, in slices of
	// a hundredth of a second, because a burst of 50,000 SYNs overruns the accept backlog and
	// the refusals that follow are the RAMP's, not the server's ceiling.
	perTick := *rate / 100
	if perTick < 1 {
		perTick = 1
	}
	ticker := time.NewTicker(10 * time.Millisecond)
	opened := 0
	for opened < *conns {
		<-ticker.C
		n := perTick
		if opened+n > *conns {
			n = *conns - opened
		}
		for i := 0; i < n; i++ {
			idx := opened + i
			wg.Add(1)
			// Each dial in its own goroutine: one slow SYN-ACK must not stall the ramp, or the
			// reported connect rate drifts below the requested one exactly when the server starts
			// to struggle — which is the moment the rate has to stay honest.
			go func(idx int) {
				defer wg.Done()
				m.dialed.Add(1)
				conn, err := dialer.Dial("tcp", *target)
				if err != nil {
					m.connFailed.Add(1)
					m.note("dial: " + err.Error())
					return
				}
				if tcp, ok := conn.(*net.TCPConn); ok && *rcvbuf > 0 {
					// The client holds as many sockets as the server. Left at the default the
					// kernel's per-socket receive memory is what stops this container first, and
					// the run reports the LOAD GENERATOR's ceiling as the server's.
					_ = tcp.SetReadBuffer(*rcvbuf)
				}
				room := "r" + strconv.Itoa(idx%*rooms)
				full := path + "?room=" + room
				if *mode == "sse-h2" {
					conn.Close() // the h2 transport dials its own, pooled across that client's streams
					runSSEH2(transports[idx / *spc], "http://"+*target+full, idx, m, *hshake)
					return
				}
				if *mode == "ws" {
					runWS(conn, full, host, idx, m, *hshake)
				} else {
					runSSE(conn, full, host, idx, m, *hshake)
				}
			}(idx)
		}
		opened += n
	}
	ticker.Stop()

	// ⚠ The ramp loop finishes when the last dial has been STARTED, not when it has finished. Taking
	// the hold's baseline here counts connections that are still in their handshake as "dropped later",
	// and the first smoke run reported a negative drop count because of it. Settle first: wait until
	// every dial has resolved one way or another.
	settleDeadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(settleDeadline) {
		if m.established.Load()+m.connFailed.Load()+m.connRejected.Load()+m.connStalled.Load() >= int64(*conns) {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}

	rampDone := time.Now()
	fmt.Printf("ramp complete in %.1fs: established=%d failed=%d rejected=%d\n",
		rampDone.Sub(startedAt).Seconds(), m.established.Load(), m.connFailed.Load(), m.connRejected.Load())

	// The hold is where the answer is. A count that was reached is not a count that is being
	// SERVED: drops, slow-consumer closes and a rising p99 all appear during the hold and none
	// of them appear during the ramp.
	holdStart := time.Now()
	framesAtHoldStart := m.frames.Load()
	bytesAtHoldStart := m.bytesIn.Load()
	liveAtHoldStart := m.established.Load() - m.dropped.Load()
	time.Sleep(*hold)

	held := time.Since(holdStart).Seconds()
	live := m.established.Load() - m.dropped.Load()
	framesDuringHold := m.frames.Load() - framesAtHoldStart
	bytesDuringHold := m.bytesIn.Load() - bytesAtHoldStart

	m.stop.Store(true)

	// expectedFrames is the tick rate times the connections that were live for the whole hold.
	// deliveryRatio below 1 means frames the server composed never reached a client, and it is
	// the one figure that separates "held 50,000 connections" from "served 50,000 connections".
	summary := map[string]any{
		"id":               *id,
		"mode":             *mode,
		"target":           *target,
		"requestedConns":   *conns,
		"rampRate":         *rate,
		"rooms":            *rooms,
		"streamsPerConn":   *spc,
		"rampSeconds":      rampDone.Sub(startedAt).Seconds(),
		"holdSeconds":      held,
		"dialed":           m.dialed.Load(),
		"established":      m.established.Load(),
		"firstFrameSeen":   m.firstFrame.Load(),
		"connFailed":       m.connFailed.Load(),
		"connRejected":     m.connRejected.Load(),
		"connStalled":      m.connStalled.Load(),
		"droppedTotal":     m.dropped.Load(),
		"liveAtHoldStart":  liveAtHoldStart,
		"liveAtEnd":        live,
		"droppedDuringHold": liveAtHoldStart - live,
		"framesDuringHold": framesDuringHold,
		"framesPerSec":     float64(framesDuringHold) / held,
		"bytesPerSec":      float64(bytesDuringHold) / held,
		"mbitPerSec":       float64(bytesDuringHold) * 8 / held / 1e6,
		"malformed":        m.malformed.Load(),
		"latencyMillis":    m.lat.percentilesMillis(),
		"clientGoroutines": runtime.NumGoroutine(),
		"clientHeapMb":     heapMb(),
		"errors":           m.noteSnapshot(),
	}
	if live > 0 {
		summary["expectedFramesDuringHold"] = float64(live) * held
		summary["deliveryRatio"] = float64(framesDuringHold) / (float64(live) * held)
	}

	enc, _ := json.MarshalIndent(summary, "", "  ")
	fmt.Println(string(enc))
	if *out != "" {
		if err := os.WriteFile(*out, enc, 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "write summary:", err)
		}
	}
}

func heapMb() float64 {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return float64(ms.HeapAlloc) / 1048576.0
}

func report(m *metrics, startedAt time.Time) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	lastFrames := int64(0)
	lastAt := startedAt
	for range ticker.C {
		if m.stopping() {
			return
		}
		now := time.Now()
		frames := m.frames.Load()
		elapsed := now.Sub(lastAt).Seconds()
		p := m.lat.percentilesMillis()
		fmt.Printf("[%5.0fs] live=%-7d est=%-7d fail=%-6d rej=%-6d stall=%-6d drop=%-6d frames/s=%-8.0f p50=%.1fms p99=%.1fms heap=%.0fMB\n",
			now.Sub(startedAt).Seconds(),
			m.established.Load()-m.dropped.Load(), m.established.Load(),
			m.connFailed.Load(), m.connRejected.Load(), m.connStalled.Load(), m.dropped.Load(),
			float64(frames-lastFrames)/elapsed, p["p50"], p["p99"], heapMb())
		lastFrames, lastAt = frames, now
	}
}

var _ = sort.Ints
