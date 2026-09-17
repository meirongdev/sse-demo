package com.meirongdev.ssefx;

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

/** The same field names the servlet module publishes, so one bench script reads both. */
@Component
@Endpoint(id = "bench")
public class BenchEndpoint {

    private final Registry registry;

    public BenchEndpoint(Registry registry) {
        this.registry = registry;
    }

    @ReadOperation
    public Map<String, Object> read() {
        Runtime runtime = Runtime.getRuntime();
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("liveSessions", registry.liveSessions());
        out.put("rooms", registry.rooms().size());
        out.put("connectsAccepted", registry.connects.sum());
        out.put("disconnects", registry.disconnects.sum());
        out.put("framesWritten", registry.framesWritten.sum());
        out.put("slowConsumerClosed", registry.dropped.sum());
        out.put("ticksPublished", registry.ticksPublished.sum());
        long ticks = registry.ticksPublished.sum();
        out.put("fanOutMeanMillis", ticks == 0 ? 0.0 : registry.fanOutMicros.sum() / (double) ticks / 1000.0);
        out.put("fanOutMaxMillis", registry.fanOutMaxMicros.sum() / 1000.0);
        out.put("heapUsedMb", (runtime.totalMemory() - runtime.freeMemory()) / 1048576.0);
        out.put("heapLiveMb", heapLiveMb());
        out.put("heapCommittedMb", runtime.totalMemory() / 1048576.0);
        out.put("heapMaxMb", runtime.maxMemory() / 1048576.0);
        out.put("gcCount", gcCount());
        out.put("rssMb", rssMb());
        out.put("platformThreads", ManagementFactory.getThreadMXBean().getThreadCount());
        out.put("openFds", openFds());
        out.put("queueDepth", registry.queueDepth());
        return out;
    }

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

    private static double rssMb() {
        try {
            for (String line : Files.readAllLines(Path.of("/proc/self/status"))) {
                if (line.startsWith("VmRSS:")) {
                    return Long.parseLong(line.replaceAll("\\D+", "")) / 1024.0;
                }
            }
        } catch (IOException | RuntimeException notLinux) {
            // no /proc outside a Linux container
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
