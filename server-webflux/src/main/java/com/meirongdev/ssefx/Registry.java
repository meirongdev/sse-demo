package com.meirongdev.ssefx;

import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Sinks;

/**
 * {@code room → sinks}. The reactive counterpart of the servlet module's registry.
 *
 * <p><b>What replaces the bounded queue and the virtual thread.</b> On the servlet side each connection had
 * an {@code ArrayBlockingQueue} and a virtual thread blocking on it. Here each connection is a
 * {@link Sinks.Many} with {@code onBackpressureBuffer} of the same depth, and Netty's event loop does the
 * writing. <b>The rule is kept: a full buffer terminates the connection rather than growing.</b> That is the
 * same slow-consumer policy, expressed in the idiom of this stack — without it the two servers would differ
 * in behaviour as well as in architecture, and the comparison would not be one.
 *
 * <p>⚠ <b>There is no per-connection thread here at all</b>, which is the point of the experiment: the servlet
 * module spends 1-2 KB of parked virtual thread per connection and Netty spends none.
 */
@Component
public class Registry {

    public final LongAdder framesWritten = new LongAdder();
    public final LongAdder dropped = new LongAdder();
    public final LongAdder connects = new LongAdder();
    public final LongAdder disconnects = new LongAdder();
    public final LongAdder ticksPublished = new LongAdder();
    public final LongAdder fanOutMicros = new LongAdder();
    public final LongAdder fanOutMaxMicros = new LongAdder();

    private final Map<String, Set<Sinks.Many<Frame>>> byRoom = new ConcurrentHashMap<>();
    private final AtomicLong live = new AtomicLong();
    private final int queueDepth;

    public Registry(@Value("${demo.queue-depth:256}") int queueDepth) {
        this.queueDepth = queueDepth;
    }

    public Sinks.Many<Frame> open(String room) {
        Sinks.Many<Frame> sink = Sinks.many().unicast().onBackpressureBuffer(
                new java.util.concurrent.ArrayBlockingQueue<>(queueDepth));
        byRoom.compute(room, (unused, sinks) -> {
            Set<Sinks.Many<Frame>> held = sinks == null ? ConcurrentHashMap.newKeySet() : sinks;
            held.add(sink);
            return held;
        });
        live.incrementAndGet();
        connects.increment();
        return sink;
    }

    public void close(String room, Sinks.Many<Frame> sink) {
        byRoom.computeIfPresent(room, (unused, sinks) -> {
            sinks.remove(sink);
            return sinks.isEmpty() ? null : sinks;
        });
        live.decrementAndGet();
        disconnects.increment();
    }

    public Set<String> rooms() {
        return byRoom.keySet();
    }

    public Set<Sinks.Many<Frame>> sinksIn(String room) {
        return byRoom.getOrDefault(room, Set.of());
    }

    public long liveSessions() {
        return live.get();
    }

    public int queueDepth() {
        return queueDepth;
    }
}
