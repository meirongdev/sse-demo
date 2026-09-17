package com.meirongdev.ssedemo.core;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.LongAdder;
import org.springframework.stereotype.Component;

/**
 * Counters and a server-side latency histogram, shared by both transports.
 *
 * <p><b>Why a hand-rolled histogram rather than Micrometer.</b> Every one of these is incremented by a session's
 * own virtual thread, so at 50,000 connections × 1 Hz this is 50,000 writes a second across as many threads.
 * {@link LongAdder} per bucket is contention-free by construction; a timer with a percentile estimator is not,
 * and at this density the instrument would become part of what is being measured.
 *
 * <p>The histogram is <b>compose → written</b>, which is the server's own share of the delay. The number that
 * matters to a player is compose → received, and only the load generator can see that; the two together say
 * whether a p99 lives in the server or on the wire.
 */
@Component
public class Stats {

    /**
     * An HdrHistogram-shaped layout: linear below 8 µs, then <b>four sub-buckets per octave</b>, so the worst-case
     * error is 25% rather than the 100% a plain power-of-two scheme gives.
     *
     * <p><b>The resolution is the point.</b> The two transports are expected to differ by tens of percent, not by
     * multiples — a doubling-bucket histogram puts both in the same bucket and reports them as identical, which is
     * a wrong answer that looks like a clean one. The load generator uses the same layout so the two histograms
     * subtract.
     */
    private static final int SUB_BITS = 2;

    private static final int SUB_COUNT = 1 << SUB_BITS;

    private static final int LINEAR_LIMIT = SUB_COUNT << 1;

    private static final int BUCKETS = 128;

    public final LongAdder framesWritten = new LongAdder();
    public final LongAdder frameBytes = new LongAdder();
    public final LongAdder heartbeats = new LongAdder();
    public final LongAdder slowConsumerClosed = new LongAdder();
    public final LongAdder closedSlow = new LongAdder();
    public final LongAdder writeFailed = new LongAdder();
    public final LongAdder connectsAccepted = new LongAdder();
    public final LongAdder connectsRejected = new LongAdder();
    public final LongAdder disconnects = new LongAdder();
    public final LongAdder ticksPublished = new LongAdder();
    public final LongAdder fanOutMicros = new LongAdder();
    public final LongAdder fanOutMaxMicros = new LongAdder();

    private final LongAdder[] writeLatency = new LongAdder[BUCKETS];

    public Stats() {
        for (int i = 0; i < BUCKETS; i++) {
            writeLatency[i] = new LongAdder();
        }
    }

    public void recordWriteLatencyMicros(long micros) {
        writeLatency[bucketOf(micros)].increment();
    }

    static int bucketOf(long micros) {
        if (micros < 0) {
            return 0;
        }
        if (micros < LINEAR_LIMIT) {
            return (int) micros;
        }
        int exponent = 63 - Long.numberOfLeadingZeros(micros);
        int sub = (int) ((micros >>> (exponent - SUB_BITS)) & (SUB_COUNT - 1));
        int index = LINEAR_LIMIT + ((exponent - (SUB_BITS + 1)) << SUB_BITS) + sub;
        return Math.min(index, BUCKETS - 1);
    }

    /** The bucket's upper bound in microseconds, so every reported percentile is an over-estimate and never a flattering one. */
    static double upperBoundMicros(int index) {
        if (index < LINEAR_LIMIT) {
            return index;
        }
        int k = index - LINEAR_LIMIT;
        int exponent = (SUB_BITS + 1) + (k >> SUB_BITS);
        int sub = k & (SUB_COUNT - 1);
        double width = Math.pow(2, exponent - SUB_BITS);
        return Math.pow(2, exponent) + (sub + 1) * width;
    }

    /** Percentiles of the compose → written histogram, in milliseconds. Bucket upper bounds, so each is an over-estimate. */
    public Map<String, Double> writeLatencyMillis() {
        long[] counts = new long[BUCKETS];
        long total = 0;
        for (int i = 0; i < BUCKETS; i++) {
            counts[i] = writeLatency[i].sum();
            total += counts[i];
        }
        Map<String, Double> out = new LinkedHashMap<>();
        if (total == 0) {
            return out;
        }
        out.put("p50", percentile(counts, total, 0.50));
        out.put("p95", percentile(counts, total, 0.95));
        out.put("p99", percentile(counts, total, 0.99));
        out.put("p999", percentile(counts, total, 0.999));
        out.put("max", percentile(counts, total, 1.0));
        return out;
    }

    private static double percentile(long[] counts, long total, double q) {
        long target = (long) Math.ceil(q * total);
        long seen = 0;
        for (int i = 0; i < counts.length; i++) {
            seen += counts[i];
            if (seen >= target) {
                return upperBoundMicros(i) / 1000.0;
            }
        }
        return upperBoundMicros(counts.length - 1) / 1000.0;
    }

    public void reset() {
        framesWritten.reset();
        frameBytes.reset();
        heartbeats.reset();
        slowConsumerClosed.reset();
        closedSlow.reset();
        writeFailed.reset();
        connectsAccepted.reset();
        connectsRejected.reset();
        disconnects.reset();
        ticksPublished.reset();
        fanOutMicros.reset();
        fanOutMaxMicros.reset();
        for (LongAdder bucket : writeLatency) {
            bucket.reset();
        }
    }
}
