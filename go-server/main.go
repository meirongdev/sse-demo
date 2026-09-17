// The same SSE server, in Go. Standard library only.
//
// The point of this module is the FLOOR: the JVM measurements range from 148 KB of RSS per connection
// on Tomcat to 36 KB on Netty, and the useful question is how much of that is the JVM and how much is
// the work itself. A runtime with no GC heap to size, no metaspace and a 2 KB starting stack per
// goroutine is the other end of that range.
//
// Everything that is not the language is copied from the servlet module: a 265-byte frame padded to
// exactly that size, a 1 Hz tick composed ONCE per room, a bounded 256-deep queue per connection, and
// a full queue closes the connection rather than growing. The stats endpoint publishes the same field
// names on the same port, so the same bench scripts read it.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	frameBytes = 265
	queueDepth = 256
)

type session struct {
	ch   chan []byte
	once sync.Once
	done chan struct{}
}

func (s *session) close() {
	s.once.Do(func() { close(s.done) })
}

type registry struct {
	mu    sync.RWMutex
	rooms map[string]map[*session]struct{}

	live        atomic.Int64
	connects    atomic.Int64
	disconnects atomic.Int64
	frames      atomic.Int64
	dropped     atomic.Int64
	ticks       atomic.Int64
	fanOutMax   atomic.Int64
}

func (r *registry) open(room string) *session {
	s := &session{ch: make(chan []byte, queueDepth), done: make(chan struct{})}
	r.mu.Lock()
	if r.rooms[room] == nil {
		r.rooms[room] = make(map[*session]struct{})
	}
	r.rooms[room][s] = struct{}{}
	r.mu.Unlock()
	r.live.Add(1)
	r.connects.Add(1)
	return s
}

func (r *registry) close(room string, s *session) {
	r.mu.Lock()
	if set := r.rooms[room]; set != nil {
		delete(set, s)
		if len(set) == 0 {
			delete(r.rooms, room)
		}
	}
	r.mu.Unlock()
	r.live.Add(-1)
	r.disconnects.Add(1)
	s.close()
}

// tick composes one frame per room and hands the SAME byte slice to every session in it —
// one allocation per room per second rather than one per connection.
func (r *registry) tick(seq int64) {
	start := time.Now()
	r.mu.RLock()
	rooms := make([]string, 0, len(r.rooms))
	for room := range r.rooms {
		rooms = append(rooms, room)
	}
	r.mu.RUnlock()

	for _, room := range rooms {
		r.mu.RLock()
		set := r.rooms[room]
		members := make([]*session, 0, len(set))
		for s := range set {
			members = append(members, s)
		}
		r.mu.RUnlock()
		if len(members) == 0 {
			continue
		}
		wire := composeFrame(room, seq)
		for _, s := range members {
			select {
			case s.ch <- wire:
				r.frames.Add(1)
			default:
				// Bounded queue full: close, never grow. The same rule the servlet module holds.
				r.dropped.Add(1)
				s.close()
			}
		}
	}
	elapsed := time.Since(start).Microseconds()
	r.ticks.Add(1)
	for {
		old := r.fanOutMax.Load()
		if elapsed <= old || r.fanOutMax.CompareAndSwap(old, elapsed) {
			break
		}
	}
}

// composeFrame builds the wire bytes for one SSE event, padded so the PAYLOAD is exactly
// frameBytes — identical arithmetic to the Java modules, so the bytes on the wire match.
func composeFrame(room string, seq int64) []byte {
	ts := time.Now().UnixMicro()
	head := `{"type":"pool_update","room":"` + room + `","seq":` + strconv.FormatInt(seq, 10) +
		`,"ts":` + strconv.FormatInt(ts, 10) +
		`,"tiers":[{"k":"mini","a":"1234.56"},{"k":"minor","a":"12345.67"},` +
		`{"k":"major","a":"123456.78"},{"k":"grand","a":"1234567.89"}],"cur":"TRY","pad":"`
	tail := `"}`
	pad := frameBytes - len(head) - len(tail)
	if pad < 0 {
		pad = 0
	}
	var b strings.Builder
	b.Grow(6 + frameBytes + 2)
	b.WriteString("data:")
	b.WriteString(head)
	b.WriteString(strings.Repeat("x", pad))
	b.WriteString(tail)
	b.WriteString("\n\n")
	return []byte(b.String())
}

func main() {
	reg := &registry{rooms: make(map[string]map[*session]struct{})}

	interval := 1000
	if v := os.Getenv("TICK_INTERVAL_MS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			interval = n
		}
	}

	go func() {
		t := time.NewTicker(time.Duration(interval) * time.Millisecond)
		defer t.Stop()
		var seq int64
		for range t.C {
			seq++
			reg.tick(seq)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/sse/stream", func(w http.ResponseWriter, req *http.Request) {
		room := req.URL.Query().Get("room")
		if room == "" {
			room = "r0"
		}
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "no flush", http.StatusInternalServerError)
			return
		}
		h := w.Header()
		h.Set("Content-Type", "text/event-stream")
		h.Set("Cache-Control", "no-cache")
		h.Set("X-Accel-Buffering", "no")
		w.WriteHeader(http.StatusOK)
		// Committed before the first frame, for the same reason the servlet module flushes early:
		// the load generator counts a connection as established when the 200 arrives.
		flusher.Flush()

		s := reg.open(room)
		defer reg.close(room, s)

		ctx := req.Context()
		for {
			select {
			case wire := <-s.ch:
				if _, err := w.Write(wire); err != nil {
					return
				}
				flusher.Flush()
			case <-s.done:
				return
			case <-ctx.Done():
				return
			}
		}
	})

	stats := http.NewServeMux()
	stats.HandleFunc("/actuator/health", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"status":"UP"}`)
	})
	// The same field names the JVM modules publish, so one set of bench scripts reads every server.
	// heapLiveMb carries Go's HeapAlloc, but ⚠ the only figure comparable ACROSS runtimes is rssMb:
	// a JVM live set, a Go heap and a Rust allocator's arena are three different things.
	stats.HandleFunc("/actuator/bench", func(w http.ResponseWriter, _ *http.Request) {
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)
		ticks := reg.ticks.Load()
		out := map[string]any{
			"liveSessions":       reg.live.Load(),
			"connectsAccepted":   reg.connects.Load(),
			"disconnects":        reg.disconnects.Load(),
			"framesWritten":      reg.frames.Load(),
			"slowConsumerClosed": reg.dropped.Load(),
			"ticksPublished":     ticks,
			"fanOutMaxMillis":    float64(reg.fanOutMax.Load()) / 1000.0,
			"heapLiveMb":         float64(ms.HeapAlloc) / 1048576.0,
			"heapUsedMb":         float64(ms.HeapInuse) / 1048576.0,
			"gcCount":            ms.NumGC,
			"rssMb":              rssMb(),
			"platformThreads":    runtime.NumGoroutine(),
			"openFds":            openFds(),
			"queueDepth":         queueDepth,
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
	})

	go func() { log.Fatal(http.ListenAndServe(":9090", stats)) }()
	srv := &http.Server{Addr: ":8080", Handler: mux}
	log.Fatal(srv.ListenAndServe())
}

func rssMb() float64 {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return -1
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "VmRSS:") {
			f := strings.Fields(line)
			if len(f) >= 2 {
				if kb, err := strconv.ParseFloat(f[1], 64); err == nil {
					return kb / 1024.0
				}
			}
		}
	}
	return -1
}

func openFds() int {
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		return -1
	}
	return len(entries)
}
