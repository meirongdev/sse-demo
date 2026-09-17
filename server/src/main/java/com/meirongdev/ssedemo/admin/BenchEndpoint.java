package com.meirongdev.ssedemo.admin;

import com.meirongdev.ssedemo.core.Registry;
import com.meirongdev.ssedemo.core.Stats;
import java.io.IOException;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryPoolMXBean;
import java.lang.management.MemoryType;
import java.lang.management.MemoryUsage;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.stereotype.Component;

/**
 * {@code GET :9090/actuator/bench} — everything the run script needs, in one object.
 *
 * <p><b>On the management port, and that is not tidiness.</b> The connection port is the thing under test, and at
 * the ceiling it is by definition refusing connections — including the run script's. A stats endpoint that goes
 * dark exactly when the interesting thing happens would leave the run with no reading at the only moment that
 * matters.
 */
@Component
@Endpoint(id = "bench")
public class BenchEndpoint {

    private final Registry registry;
    private final Stats stats;

    public BenchEndpoint(Registry registry, Stats stats) {
        this.registry = registry;
        this.stats = stats;
    }

    @ReadOperation
    public Map<String, Object> read() {
        Runtime runtime = Runtime.getRuntime();
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("liveSessions", registry.liveSessions());
        out.put("rooms", registry.rooms().size());
        out.put("connectsAccepted", stats.connectsAccepted.sum());
        out.put("connectsRejected", stats.connectsRejected.sum());
        out.put("disconnects", stats.disconnects.sum());
        out.put("framesWritten", stats.framesWritten.sum());
        out.put("frameBytes", stats.frameBytes.sum());
        out.put("heartbeats", stats.heartbeats.sum());
        out.put("slowConsumerClosed", stats.slowConsumerClosed.sum());
        out.put("writeFailed", stats.writeFailed.sum());
        out.put("ticksPublished", stats.ticksPublished.sum());

        long ticks = stats.ticksPublished.sum();
        out.put("fanOutMeanMillis", ticks == 0 ? 0.0 : stats.fanOutMicros.sum() / (double) ticks / 1000.0);
        out.put("fanOutMaxMillis", stats.fanOutMaxMicros.sum() / 1000.0);
        out.put("writeLatencyMillis", stats.writeLatencyMillis());

        // ⚠ heapUsed INCLUDES GARBAGE, and at a 5.6 GB ceiling G1 has no reason to collect: the first run of
        // this harness read 286 MB at 2,000 connections and would have reported 143 KB of "per-connection cost"
        // that was mostly floating garbage. heapLive is the live set after the last collection — the only one of
        // the three that answers "what does a connection cost".
        out.put("heapUsedMb", (runtime.totalMemory() - runtime.freeMemory()) / 1048576.0);
        out.put("heapLiveMb", heapLiveMb());
        out.put("heapCommittedMb", runtime.totalMemory() / 1048576.0);
        out.put("heapMaxMb", runtime.maxMemory() / 1048576.0);
        out.put("gcCount", gcCount());
        out.put("gcTimeMs", gcTimeMs());
        out.put("rssMb", rssMb());
        // ⚠ Thread.activeCount() counts the CURRENT thread group, and an actuator call arrives on a virtual
        // thread whose group is not the platform one — it read 0 on the first run. Platform threads are the
        // meaningful count here anyway: the per-connection writers are virtual and are not OS threads at all.
        out.put("platformThreads", ManagementFactory.getThreadMXBean().getThreadCount());
        out.put("openFds", openFds());
        out.put("queueDepth", registry.queueDepth());
        return out;
    }

    /**
     * The live set after the most recent collection, summed over the heap pools. Zero until the first GC, which
     * at these heap sizes may not happen during a short run — a zero here means "not yet collected", not "empty".
     */
    private static double heapLiveMb() {
        long live = 0;
        for (MemoryPoolMXBean pool : ManagementFactory.getMemoryPoolMXBeans()) {
            if (pool.getType() == MemoryType.HEAP) {
                MemoryUsage afterGc = pool.getCollectionUsage();
                if (afterGc != null) {
                    live += afterGc.getUsed();
                }
            }
        }
        return live / 1048576.0;
    }

    private static long gcCount() {
        long count = 0;
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            count += Math.max(0, gc.getCollectionCount());
        }
        return count;
    }

    private static long gcTimeMs() {
        long millis = 0;
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            millis += Math.max(0, gc.getCollectionTime());
        }
        return millis;
    }

    /** {@code VmRSS} is the whole process — heap, metaspace, thread stacks, NIO buffers and kernel-visible mappings. It is the number an 8 GB cgroup limit actually enforces against, and the JVM's own heap figure is not. */
    private static double rssMb() {
        try {
            for (String line : Files.readAllLines(Path.of("/proc/self/status"))) {
                if (line.startsWith("VmRSS:")) {
                    return Long.parseLong(line.replaceAll("\\D+", "")) / 1024.0;
                }
            }
        } catch (IOException | RuntimeException notLinux) {
            // macOS has no /proc. The run of record is in a container; this is the fallback for a local smoke test.
        }
        return -1;
    }

    private static long openFds() {
        try (var entries = Files.list(Path.of("/proc/self/fd"))) {
            return entries.count();
        } catch (IOException | RuntimeException notLinux) {
            return -1;
        }
    }
}
