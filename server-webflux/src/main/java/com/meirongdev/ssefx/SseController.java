package com.meirongdev.ssefx;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Sinks;

/** {@code GET /sse/stream?room=} — the same event stream, written by Netty instead of Tomcat. */
@RestController
public class SseController {

    private final Registry registry;

    public SseController(Registry registry) {
        this.registry = registry;
    }

    /**
     * ⚠ Returns {@code Flux<String>} rather than {@code Flux<ServerSentEvent<String>>}.
     *
     * <p>The two produce the same wire for a payload with no event name or id — {@code data:…\n\n} — but
     * {@code ServerSentEvent} allocates a wrapper per frame per subscriber, which at 20,000 subscribers is
     * 20,000 allocations a second spent on nothing. <b>The servlet module does not allocate one either</b>,
     * so this keeps the two comparable rather than handing Netty a penalty Tomcat is not paying.
     */
    @GetMapping(path = "/sse/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public Flux<String> open(@RequestParam(name = "room", defaultValue = "r0") String room) {
        Sinks.Many<Frame> sink = registry.open(room);
        return sink.asFlux()
                .map(Frame::json)
                .doFinally(signal -> registry.close(room, sink));
    }
}
