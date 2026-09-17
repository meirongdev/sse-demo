package main

import (
	"math"
	"math/bits"
	"sync/atomic"
)

// An HdrHistogram-shaped layout, IDENTICAL to the server's Stats.bucketOf: linear below 8 µs,
// then four sub-buckets per octave, so the worst-case error is 25% rather than the 100% a plain
// doubling scheme gives.
//
// The resolution is the point. The two transports are expected to differ by tens of percent, not
// by multiples — a doubling-bucket histogram puts both in the same bucket and reports them as
// identical, which is a wrong answer that looks like a clean one. Sharing the layout with the
// server is what lets its compose-to-written histogram be subtracted from this one's
// compose-to-received to say where a p99 actually lives.
const (
	subBits     = 2
	subCount    = 1 << subBits
	linearLimit = subCount << 1
	buckets     = 128
)

// shards exist to keep 50,000 goroutines off one cache line. At 1 Hz each connection records
// once a second, and without sharding the hot bucket — every frame lands in two or three of
// them — would be a single contended atomic for the whole run.
const shards = 64

type shard struct {
	counts [buckets]atomic.Int64
	_      [64]byte // pad past a cache line so neighbouring shards do not share one
}

type hist struct {
	s [shards]shard
}

func bucketOf(micros int64) int {
	if micros < 0 {
		return 0
	}
	if micros < linearLimit {
		return int(micros)
	}
	exponent := 63 - bits.LeadingZeros64(uint64(micros))
	sub := int((micros >> uint(exponent-subBits)) & (subCount - 1))
	idx := linearLimit + ((exponent - (subBits + 1)) << subBits) + sub
	if idx >= buckets {
		return buckets - 1
	}
	return idx
}

// upperBoundMicros is the bucket's upper bound, so every reported percentile is an
// over-estimate and never a flattering one.
func upperBoundMicros(index int) float64 {
	if index < linearLimit {
		return float64(index)
	}
	k := index - linearLimit
	exponent := (subBits + 1) + (k >> subBits)
	sub := k & (subCount - 1)
	width := math.Pow(2, float64(exponent-subBits))
	return math.Pow(2, float64(exponent)) + float64(sub+1)*width
}

func (h *hist) record(idx int, micros int64) {
	if micros < 0 {
		// The frame outran its own timestamp. Both containers share one kernel clock so this
		// should never fire; counting it is the caller's job, and silently recording it as zero
		// would hide a clock problem inside a healthy-looking p50.
		return
	}
	h.s[idx&(shards-1)].counts[bucketOf(micros)].Add(1)
}

func (h *hist) merge() ([buckets]int64, int64) {
	var out [buckets]int64
	var total int64
	for s := range h.s {
		for b := 0; b < buckets; b++ {
			v := h.s[s].counts[b].Load()
			out[b] += v
			total += v
		}
	}
	return out, total
}

func (h *hist) percentilesMillis() map[string]float64 {
	counts, total := h.merge()
	out := map[string]float64{}
	if total == 0 {
		return out
	}
	for _, q := range []struct {
		name string
		v    float64
	}{{"p50", 0.50}, {"p90", 0.90}, {"p95", 0.95}, {"p99", 0.99}, {"p999", 0.999}, {"max", 1.0}} {
		target := int64(math.Ceil(q.v * float64(total)))
		var seen int64
		for i := 0; i < buckets; i++ {
			seen += counts[i]
			if seen >= target {
				out[q.name] = upperBoundMicros(i) / 1000.0
				break
			}
		}
	}
	return out
}
