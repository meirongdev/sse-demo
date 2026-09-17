package com.meirongdev.ssedemo.core;

import java.io.IOException;

/**
 * The one seam that knows a transport. Everything above it — the bounded queue, the write loop, the heartbeat
 * rule, the slow-consumer close, the registry — is shared, so that <b>the transport is the only variable in
 * the experiment</b>.
 */
public interface Sink {

    /** Writes one frame and flushes it. Blocking: the caller is this session's own virtual thread. */
    void write(Frame frame) throws IOException;

    /** Keeps a quiet connection open through the smallest idle timeout on the path. */
    void heartbeat() throws IOException;

    /** The container's own signal that the peer is gone, wired to the same close path the server uses. */
    void onClientGone(Runnable callback);

    void close();

    /** For the report: what this transport adds to {@link Frame#payloadBytes()} for one frame. */
    int framingOverheadBytes();
}
