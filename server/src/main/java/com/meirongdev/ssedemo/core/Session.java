package com.meirongdev.ssedemo.core;

import java.io.IOException;
import java.time.Duration;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

/**
 * One open connection, the virtual thread that writes to it, and the rules — a bounded queue, a heartbeat when
 * idle, and a close when the queue is full.
 *
 * <p><b>Identical for both transports.</b> Copied in shape from the reference service's
 * {@code Session} so the density this harness measures is the density that design would get: one virtual thread
 * per connection blocking on a queue, ~1-2 KB of heap parked per connection.
 *
 * <p>⚠ <b>A full queue closes the connection; it does not slow the write.</b> Buffering for an absent reader is
 * durable state with extra steps. It also matters to the measurement: without this rule a stalled consumer
 * quietly grows the heap and the run reports a connection count the server was not actually serving.
 */
public final class Session {

    private final long id;
    private final String room;
    private final Sink sink;
    private final BlockingQueue<Frame> queue;
    private final Duration heartbeatInterval;
    private final Stats stats;
    private final AtomicBoolean open = new AtomicBoolean(true);
    private final Consumer<Session> onClose;

    public Session(
            long id, String room, Sink sink, int queueDepth, Duration heartbeatInterval, Stats stats, Consumer<Session> onClose) {
        this.id = id;
        this.room = room;
        this.sink = sink;
        this.queue = new ArrayBlockingQueue<>(queueDepth);
        this.heartbeatInterval = heartbeatInterval;
        this.stats = stats;
        this.onClose = onClose;
    }

    public long id() {
        return id;
    }

    public String room() {
        return room;
    }

    public Sink sink() {
        return sink;
    }

    /**
     * Starts the write loop.
     *
     * <p>Separate from construction: a session is registered before the response is committed and started after
     * it, so a close in between must still reach the registry.
     */
    public void start() {
        sink.onClientGone(() -> close(false));
        Thread.ofVirtual().name("session-" + id).start(this::writeLoop);
    }

    /** @return whether the frame was queued. A full queue is a closed connection, not a slower write. */
    public boolean enqueue(Frame frame) {
        if (!open.get()) {
            return false;
        }
        if (!queue.offer(frame)) {
            stats.slowConsumerClosed.increment();
            close(true);
            return false;
        }
        return true;
    }

    private void writeLoop() {
        try {
            while (open.get()) {
                Frame frame = queue.poll(heartbeatInterval.toMillis(), TimeUnit.MILLISECONDS);
                if (frame == null) {
                    sink.heartbeat();
                    stats.heartbeats.increment();
                } else {
                    sink.write(frame);
                    stats.framesWritten.increment();
                    stats.frameBytes.add(frame.payloadBytes() + sink.framingOverheadBytes());
                    stats.recordWriteLatencyMicros(Frame.nowMicros() - frame.composedAtMicros());
                }
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            close(false);
        } catch (IOException | RuntimeException writeFailed) {
            stats.writeFailed.increment();
            close(false);
        }
    }

    public void close(boolean slowConsumer) {
        if (!open.compareAndSet(true, false)) {
            return;
        }
        onClose.accept(this);
        if (slowConsumer) {
            stats.closedSlow.increment();
        }
        try {
            sink.close();
        } catch (RuntimeException alreadyGone) {
            // The container may have torn the connection down already. Nothing to recover.
        }
    }
}
