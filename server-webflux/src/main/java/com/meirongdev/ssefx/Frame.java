package com.meirongdev.ssefx;

import java.nio.charset.StandardCharsets;
import java.time.Instant;

/**
 * Byte-for-byte the servlet module's {@code Frame}, copied rather than shared.
 *
 * <p>Copied on purpose: a shared module would have coupled the two servers' build, and the whole value of
 * this one is that it changes exactly one thing. <b>The padding arithmetic and the 265-byte default are
 * identical, so the two stacks carry the same bytes at the same rate</b> — if they did not, the comparison
 * would be measuring frame size.
 */
public record Frame(String json, long composedAtMicros) {

    public static long nowMicros() {
        Instant now = Instant.now();
        return now.getEpochSecond() * 1_000_000L + now.getNano() / 1_000;
    }

    public static Frame tick(String room, long seq, int targetBytes) {
        long ts = nowMicros();
        String head = "{\"type\":\"pool_update\",\"room\":\"" + room + "\",\"seq\":" + seq + ",\"ts\":" + ts
                + ",\"tiers\":[{\"k\":\"mini\",\"a\":\"1234.56\"},{\"k\":\"minor\",\"a\":\"12345.67\"},"
                + "{\"k\":\"major\",\"a\":\"123456.78\"},{\"k\":\"grand\",\"a\":\"1234567.89\"}],\"cur\":\"TRY\",\"pad\":\"";
        String tail = "\"}";
        int pad = targetBytes - head.length() - tail.length();
        return new Frame(head + (pad > 0 ? "x".repeat(pad) : "") + tail, ts);
    }

    public int payloadBytes() {
        return json.getBytes(StandardCharsets.UTF_8).length;
    }
}
