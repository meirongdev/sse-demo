package com.meirongdev.ssedemo.core;

import java.nio.charset.StandardCharsets;
import java.time.Instant;

/**
 * One tick's payload, composed once and written to every session.
 *
 * <p><b>This is the fairness contract of the whole harness.</b> Both transports carry the same {@link #json()} —
 * the same characters, the same byte count, the same embedded timestamp. What differs downstream is framing and
 * nothing else: SSE wraps it in {@code data: …\n\n} inside a chunked response, WebSocket wraps it in a text frame
 * with a 2-to-4 byte header. If the measurement shows a difference, that difference is the wire.
 *
 * <p>Composed once per tick per room rather than once per session — TD §5.6.1 lever 1. At 50,000 sessions the
 * alternative is 50,000 serializations a second, which would measure Jackson rather than the transport.
 *
 * @param json the payload both transports carry, identical byte-for-byte
 * @param sseWire {@code json} pre-encoded as an SSE event, for the byte-level sink
 * @param wsWire {@code json} pre-encoded as UTF-8, for the byte-level sink
 * @param composedAtMicros when this frame was composed, for the server-side fan-out histogram
 */
public record Frame(String json, byte[] sseWire, byte[] wsWire, long composedAtMicros) {

    /** Epoch microseconds. {@code System.currentTimeMillis()} is millisecond-resolution and the p99 we expect is tens of milliseconds. */
    public static long nowMicros() {
        Instant now = Instant.now();
        return now.getEpochSecond() * 1_000_000L + now.getNano() / 1_000;
    }

    /**
     * Composes a tick of exactly {@code targetBytes} UTF-8 bytes, padded to size.
     *
     * <p><b>Frame size is a controlled variable, not an accident of the JSON.</b> The reference service's tick is
     * 265 bytes (TD §5.6.1, back-derived from 30 MB/s ÷ 113,000), so that is the default — but egress bandwidth is
     * one of the candidate walls, and a wall you cannot move is a wall you cannot identify.
     */
    public static Frame tick(String room, long seq, int targetBytes) {
        long ts = nowMicros();
        String head = "{\"type\":\"pool_update\",\"room\":\"" + room + "\",\"seq\":" + seq + ",\"ts\":" + ts
                + ",\"tiers\":[{\"k\":\"mini\",\"a\":\"1234.56\"},{\"k\":\"minor\",\"a\":\"12345.67\"},"
                + "{\"k\":\"major\",\"a\":\"123456.78\"},{\"k\":\"grand\",\"a\":\"1234567.89\"}],\"cur\":\"TRY\",\"pad\":\"";
        String tail = "\"}";
        // Every character above is ASCII, so bytes and chars are the same count and the padding is exact.
        int pad = targetBytes - head.length() - tail.length();
        String json = head + (pad > 0 ? "x".repeat(pad) : "") + tail;
        return of(json, ts);
    }

    public static Frame of(String json, long composedAtMicros) {
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        byte[] sse = new byte[6 + body.length + 2];
        System.arraycopy("data: ".getBytes(StandardCharsets.US_ASCII), 0, sse, 0, 6);
        System.arraycopy(body, 0, sse, 6, body.length);
        sse[6 + body.length] = '\n';
        sse[7 + body.length] = '\n';
        return new Frame(json, sse, body, composedAtMicros);
    }

    /** Payload bytes on the wire, before either transport's framing. */
    public int payloadBytes() {
        return wsWire.length;
    }
}
