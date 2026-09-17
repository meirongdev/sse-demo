package com.meirongdev.ssedemo.tick;

import com.meirongdev.ssedemo.core.Frame;
import com.meirongdev.ssedemo.core.Registry;
import com.meirongdev.ssedemo.core.Session;
import com.meirongdev.ssedemo.core.Stats;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * The tick: one frame per room per interval, fanned out to whoever is connected.
 *
 * <p><b>The load does not scale with anything the clients do.</b> They send nothing; the frame rate is
 * {@code connections × 1 Hz} by construction, which is what makes the two transports comparable at all — the
 * same number of frames, the same bytes, the same cadence, on the same schedule.
 *
 * <p><b>Sharding, and why it is a session-level split rather than a room-level one.</b> The obvious way to
 * parallelise a fan-out is to give each thread a subset of rooms. <b>It would measure nothing here</b>: the
 * benchmark's default is a single room, so a room-level split leaves one thread doing all the work and reports
 * the unsharded number under a sharded label. The split is therefore over the session array, per room.
 *
 * <p>⚠ <b>Platform threads, not virtual ones.</b> The whole point is to not queue behind the tens of thousands
 * of virtual threads this fan-out is about to make runnable. A virtual-threaded fan-out would be scheduled on
 * the same carriers as its own consumers.
 *
 * <p>⚠ <b>The tick waits for its shards.</b> Fire-and-forget would let tick N+1 start before tick N finished,
 * and {@code fanOutMillis} would stop meaning anything at exactly the load where it matters.
 */
@Component
public class TickPublisher {

    private final Registry registry;
    private final Stats stats;
    private final long intervalMillis;
    private final int frameBytes;
    private final boolean enabled;
    private final int shards;

    private ScheduledExecutorService scheduler;
    private ExecutorService fanOut;
    private long seq;

    public TickPublisher(
            Registry registry,
            Stats stats,
            @Value("${demo.tick-interval-ms:1000}") long intervalMillis,
            @Value("${demo.frame-bytes:265}") int frameBytes,
            @Value("${demo.tick-enabled:true}") boolean enabled,
            @Value("${demo.fanout-threads:1}") int shards) {
        this.registry = registry;
        this.stats = stats;
        this.intervalMillis = intervalMillis;
        this.frameBytes = frameBytes;
        this.enabled = enabled;
        this.shards = Math.max(1, shards);
    }

    @PostConstruct
    void start() {
        if (!enabled) {
            return;
        }
        scheduler = Executors.newSingleThreadScheduledExecutor(runnable -> platform(runnable, "tick"));
        if (shards > 1) {
            AtomicInteger n = new AtomicInteger();
            fanOut = Executors.newFixedThreadPool(shards, runnable -> platform(runnable, "fanout-" + n.incrementAndGet()));
        }
        scheduler.scheduleAtFixedRate(this::publish, intervalMillis, intervalMillis, TimeUnit.MILLISECONDS);
    }

    private static Thread platform(Runnable runnable, String name) {
        Thread thread = new Thread(runnable, name);
        thread.setDaemon(true);
        return thread;
    }

    private void publish() {
        try {
            long startedAt = Frame.nowMicros();
            seq++;
            for (String room : registry.rooms()) {
                Set<Session> sessions = registry.sessionsIn(room);
                if (sessions.isEmpty()) {
                    continue;
                }
                // Composed ONCE per room per tick. Per session it would be 40,000 serializations a second and
                // the run would be measuring string building.
                Frame frame = Frame.tick(room, seq, frameBytes);
                if (shards == 1) {
                    for (Session session : sessions) {
                        session.enqueue(frame);
                    }
                } else {
                    fanOutSharded(sessions, frame);
                }
            }
            long elapsed = Frame.nowMicros() - startedAt;
            stats.ticksPublished.increment();
            stats.fanOutMicros.add(elapsed);
            if (elapsed > stats.fanOutMaxMicros.sum()) {
                stats.fanOutMaxMicros.reset();
                stats.fanOutMaxMicros.add(elapsed);
            }
        } catch (RuntimeException failure) {
            // A throw here kills the schedule silently and the run reports a healthy server delivering nothing.
            System.err.println("tick failed: " + failure);
        }
    }

    /**
     * One snapshot of the room, split into contiguous ranges — <b>one array allocation per room per tick</b>,
     * about 320 KB at 40,000 sessions, against the alternative of every shard iterating the whole concurrent set
     * to pick out its own members.
     */
    private void fanOutSharded(Set<Session> sessions, Frame frame) {
        Session[] snapshot = sessions.toArray(new Session[0]);
        int size = snapshot.length;
        int chunk = (size + shards - 1) / shards;
        List<Callable<Void>> tasks = new ArrayList<>(shards);
        for (int start = 0; start < size; start += chunk) {
            int from = start;
            int to = Math.min(start + chunk, size);
            tasks.add(() -> {
                for (int i = from; i < to; i++) {
                    snapshot[i].enqueue(frame);
                }
                return null;
            });
        }
        try {
            // invokeAll blocks until every shard is done, which is what keeps fanOutMillis honest.
            fanOut.invokeAll(tasks);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    @PreDestroy
    void stop() {
        if (scheduler != null) {
            scheduler.shutdownNow();
        }
        if (fanOut != null) {
            fanOut.shutdownNow();
        }
    }
}
