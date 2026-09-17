package com.meirongdev.ssedemo.ws;

import com.meirongdev.ssedemo.core.Frame;
import com.meirongdev.ssedemo.core.Sink;
import java.io.IOException;
import java.nio.ByteBuffer;
import org.springframework.web.socket.BinaryMessage;
import org.springframework.web.socket.PingMessage;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;

/**
 * The same frame, through a WebSocket text frame instead.
 *
 * <p><b>No {@code ConcurrentWebSocketSessionDecorator}</b>, deliberately, on both counts that matter here: this
 * session has exactly one writer — its own virtual thread — so the decorator guards nothing, and its send buffer
 * would add per-connection heap to the one quantity this harness exists to measure.
 *
 * <p>⚠ {@code bytes} mode sends a <b>binary</b> frame, which is a different opcode and therefore not the same
 * wire. It is here because it is the only way to hand Tomcat bytes that were encoded once per tick rather than
 * once per session, and the difference it makes is a real finding — but it is a change a client must agree to,
 * unlike SSE's, which is invisible to one.
 */
public final class WsSink implements Sink {

    /** 2-byte header below 126 payload bytes, 4 at or above, and server-to-client frames are never masked. */
    private static final int FRAMING_OVERHEAD = 4;

    private final WebSocketSession session;
    private final boolean preEncoded;

    public WsSink(WebSocketSession session, boolean preEncoded) {
        this.session = session;
        this.preEncoded = preEncoded;
    }

    @Override
    public void write(Frame frame) throws IOException {
        if (preEncoded) {
            session.sendMessage(new BinaryMessage(ByteBuffer.wrap(frame.wsWire())));
        } else {
            session.sendMessage(new TextMessage(frame.json()));
        }
    }

    @Override
    public void heartbeat() throws IOException {
        session.sendMessage(new PingMessage());
    }

    @Override
    public void onClientGone(Runnable callback) {
        // Wired by WsHandler#afterConnectionClosed instead: the container hands the close to the handler, not
        // to the session object, so there is nothing to register here.
    }

    @Override
    public void close() {
        try {
            session.close();
        } catch (IOException | RuntimeException alreadyGone) {
            // Closed by the container already.
        }
    }

    @Override
    public int framingOverheadBytes() {
        return FRAMING_OVERHEAD;
    }
}
