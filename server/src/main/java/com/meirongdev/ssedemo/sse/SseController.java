package com.meirongdev.ssedemo.sse;

import com.meirongdev.ssedemo.core.Registry;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

/** {@code GET /sse/stream?room=} — one {@code text/event-stream} per connection. */
@RestController
public class SseController {

    private final Registry registry;
    private final boolean preEncoded;

    public SseController(Registry registry, @Value("${demo.encode:text}") String encode) {
        this.registry = registry;
        this.preEncoded = "bytes".equalsIgnoreCase(encode);
    }

    @GetMapping(path = "/sse/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter open(@RequestParam(name = "room", defaultValue = "r0") String room, HttpServletResponse response)
            throws IOException {
        SseEmitter emitter = new SseEmitter(Long.MAX_VALUE);

        // Without this flush the container holds the headers until something is written, so a connection that has
        // not yet seen a tick looks unopened. It matters to the MEASUREMENT and not only to a client: the load
        // generator counts a connection as established when the 200 arrives, and the ramp rate would otherwise be
        // reported as the tick rate.
        response.setStatus(HttpServletResponse.SC_OK);
        response.setContentType(MediaType.TEXT_EVENT_STREAM_VALUE);
        response.setHeader(HttpHeaders.CACHE_CONTROL, "no-cache");
        response.setHeader("X-Accel-Buffering", "no");
        response.flushBuffer();

        if (registry.open(room, new SseSink(emitter, preEncoded)) == null) {
            emitter.complete();
        }
        return emitter;
    }
}
