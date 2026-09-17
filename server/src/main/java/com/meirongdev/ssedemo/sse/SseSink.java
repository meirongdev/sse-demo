package com.meirongdev.ssedemo.sse;

import com.meirongdev.ssedemo.core.Frame;
import com.meirongdev.ssedemo.core.Sink;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.springframework.http.MediaType;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

/**
 * SSE over Spring MVC's {@code SseEmitter} — the transport the reference service ships.
 *
 * <p><b>Two modes, because "how many connections" and "how much CPU per frame" are different questions.</b>
 *
 * <ul>
 *   <li>{@code text} — {@code send(String)}. One UTF-8 encoding per session per frame. This is what the reference
 *       service does today and it is the default, so the headline number describes shipping code.
 *   <li>{@code bytes} — {@code send(byte[])}. The payload is encoded once per tick in {@link Frame} and the array
 *       is handed to the converter as-is. This is TD §5.6.1 lever 1 at the byte level, and the delta between the
 *       two modes is what that lever is worth.
 * </ul>
 *
 * <p>Either way the bytes on the wire are identical: {@code data: <payload>\n\n}. Only who did the encoding moves.
 */
public final class SseSink implements Sink {

    /**
     * Measured off the wire, not assumed: Spring writes {@code data:} with no space, so the event is 5 + payload
     * + {@code \n\n}, and each {@code send} is one HTTP chunk — a hex length line and two CRLFs, 7 more at this
     * size. 14 bytes on a 265-byte frame. <b>It is the one place SSE is structurally more expensive than a
     * WebSocket text frame</b>, which spends 4, and it is ~4% of egress.
     *
     * <p>⚠ The chunk header grows a byte each time the payload crosses a power of sixteen, so this constant is
     * exact for the default frame size and near enough elsewhere. <b>The authoritative egress figure is the load
     * generator's own byte counter</b>, which counts what arrived rather than what this thinks it sent.
     */
    private static final int FRAMING_OVERHEAD = 14;

    private static final MediaType TEXT_UTF8 = new MediaType(MediaType.TEXT_PLAIN, StandardCharsets.UTF_8);

    private final SseEmitter emitter;
    private final boolean preEncoded;

    public SseSink(SseEmitter emitter, boolean preEncoded) {
        this.emitter = emitter;
        this.preEncoded = preEncoded;
    }

    @Override
    public void write(Frame frame) throws IOException {
        if (preEncoded) {
            emitter.send(frame.wsWire(), MediaType.APPLICATION_OCTET_STREAM);
        } else {
            emitter.send(frame.json(), TEXT_UTF8);
        }
    }

    @Override
    public void heartbeat() throws IOException {
        emitter.send(SseEmitter.event().comment(" ping"));
    }

    @Override
    public void onClientGone(Runnable callback) {
        emitter.onCompletion(callback);
        emitter.onTimeout(callback);
        emitter.onError(failure -> callback.run());
    }

    @Override
    public void close() {
        try {
            emitter.complete();
        } catch (RuntimeException alreadyGone) {
            // Completed by the container already.
        }
    }

    @Override
    public int framingOverheadBytes() {
        return FRAMING_OVERHEAD;
    }
}
