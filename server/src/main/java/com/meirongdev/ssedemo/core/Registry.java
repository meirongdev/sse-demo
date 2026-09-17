package com.meirongdev.ssedemo.core;

import java.time.Duration;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * {@code room → sessions}, in memory, local to the instance, reconciled with nothing.
 *
 * <p>Concurrent collections rather than a lock: a lock held across a fan-out serialises it whether or not it pins
 * a carrier thread, and 50,000 writes behind one monitor is the same stall either way.
 *
 * <p>⚠ Every mutation happens inside {@code compute} on the key. {@code computeIfAbsent(k).add(s)} has a window
 * between the lookup and the add in which a concurrent deregister empties the set and removes it from the map,
 * leaving a session nothing points to — open, uncounted, and written to by no one. At a connect rate of 2,000/s
 * that window is hit within a single run.
 */
@Component
public class Registry {

    private final Map<String, Set<Session>> byRoom = new ConcurrentHashMap<>();
    private final AtomicLong nextId = new AtomicLong();
    private final AtomicLong live = new AtomicLong();

    private final int queueDepth;
    private final Duration heartbeatInterval;
    private final int maxSessions;
    private final Stats stats;

    public Registry(
            Stats stats,
            @Value("${demo.queue-depth:256}") int queueDepth,
            @Value("${demo.heartbeat-interval:15s}") Duration heartbeatInterval,
            @Value("${demo.max-sessions:1000000}") int maxSessions) {
        this.stats = stats;
        this.queueDepth = queueDepth;
        this.heartbeatInterval = heartbeatInterval;
        this.maxSessions = maxSessions;
    }

    /** @return the started session, or {@code null} when this instance is already at its admission cap. */
    public Session open(String room, Sink sink) {
        if (live.get() >= maxSessions) {
            stats.connectsRejected.increment();
            return null;
        }
        Session session = new Session(
                nextId.incrementAndGet(), room, sink, queueDepth, heartbeatInterval, stats, this::deregister);
        byRoom.compute(room, (unused, sessions) -> {
            Set<Session> held = sessions == null ? ConcurrentHashMap.newKeySet() : sessions;
            held.add(session);
            return held;
        });
        live.incrementAndGet();
        stats.connectsAccepted.increment();
        session.start();
        return session;
    }

    private void deregister(Session session) {
        byRoom.computeIfPresent(session.room(), (unused, sessions) -> {
            sessions.remove(session);
            return sessions.isEmpty() ? null : sessions;
        });
        live.decrementAndGet();
        stats.disconnects.increment();
    }

    public Set<Session> sessionsIn(String room) {
        return byRoom.getOrDefault(room, Set.of());
    }

    public Set<String> rooms() {
        return byRoom.keySet();
    }

    public long liveSessions() {
        return live.get();
    }

    public int queueDepth() {
        return queueDepth;
    }
}
