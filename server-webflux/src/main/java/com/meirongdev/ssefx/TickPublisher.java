package com.meirongdev.ssefx;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Sinks;

/**
 * One frame per room per interval, emitted into every sink. The servlet module's tick, unchanged in shape:
 * composed once per room, a platform thread doing the fan-out, and the elapsed time recorded so the two
 * stacks' fan-out cost can be compared directly.
 */
@Component
public class TickPublisher {

    private final Registry registry;
    private final long intervalMillis;
    private final int frameBytes;
    private final boolean enabled;
    private ScheduledExecutorService scheduler;
    private long seq;

    public TickPublisher(
            Registry registry,
            @Value("${demo.tick-interval-ms:1000}") long intervalMillis,
            @Value("${demo.frame-bytes:265}") int frameBytes,
            @Value("${demo.tick-enabled:true}") boolean enabled) {
        this.registry = registry;
        this.intervalMillis = intervalMillis;
        this.frameBytes = frameBytes;
        this.enabled = enabled;
    }

    @PostConstruct
    void start() {
        if (!enabled) {
            return;
        }
        scheduler = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "tick");
            t.setDaemon(true);
            return t;
        });
        scheduler.scheduleAtFixedRate(this::publish, intervalMillis, intervalMillis, TimeUnit.MILLISECONDS);
    }

    private void publish() {
        try {
            long startedAt = Frame.nowMicros();
            seq++;
            for (String room : registry.rooms()) {
                Set<Sinks.Many<Frame>> sinks = registry.sinksIn(room);
                if (sinks.isEmpty()) {
                    continue;
                }
                Frame frame = Frame.tick(room, seq, frameBytes);
                for (Sinks.Many<Frame> sink : sinks) {
                    // tryEmitNext rather than emitNext: a full buffer must be counted and dropped, never
                    // retried in a busy loop on the tick thread — the servlet module closes the connection
                    // on a full queue and this is the same refusal to buffer for an absent reader.
                    if (sink.tryEmitNext(frame).isSuccess()) {
                        registry.framesWritten.increment();
                    } else {
                        registry.dropped.increment();
                    }
                }
            }
            long elapsed = Frame.nowMicros() - startedAt;
            registry.ticksPublished.increment();
            registry.fanOutMicros.add(elapsed);
            if (elapsed > registry.fanOutMaxMicros.sum()) {
                registry.fanOutMaxMicros.reset();
                registry.fanOutMaxMicros.add(elapsed);
            }
        } catch (RuntimeException failure) {
            System.err.println("tick failed: " + failure);
        }
    }

    @PreDestroy
    void stop() {
        if (scheduler != null) {
            scheduler.shutdownNow();
        }
    }
}
