package com.meirongdev.ssefx;

import java.net.URI;
import java.util.HashMap;
import java.util.Map;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.reactive.handler.SimpleUrlHandlerMapping;
import org.springframework.web.reactive.socket.WebSocketHandler;
import org.springframework.web.reactive.socket.WebSocketSession;
import reactor.core.publisher.Mono;
import reactor.core.publisher.Sinks;

/** {@code /ws/stream?room=} on Reactor Netty, so the stack question is asked of both transports. */
@Configuration
public class WsHandler implements WebSocketHandler {

    private final Registry registry;

    public WsHandler(Registry registry) {
        this.registry = registry;
    }

    @Override
    public Mono<Void> handle(WebSocketSession session) {
        String room = room(session.getHandshakeInfo().getUri());
        Sinks.Many<Frame> sink = registry.open(room);
        return session.send(sink.asFlux().map(frame -> session.textMessage(frame.json())))
                .doFinally(signal -> registry.close(room, sink));
    }

    private static String room(URI uri) {
        String query = uri.getQuery();
        if (query != null) {
            for (String pair : query.split("&")) {
                if (pair.startsWith("room=")) {
                    return pair.substring(5);
                }
            }
        }
        return "r0";
    }

    @Bean
    public SimpleUrlHandlerMapping webSocketMapping(WsHandler handler) {
        Map<String, WebSocketHandler> map = new HashMap<>();
        map.put("/ws/stream", handler);
        SimpleUrlHandlerMapping mapping = new SimpleUrlHandlerMapping();
        mapping.setUrlMap(map);
        mapping.setOrder(-1);
        return mapping;
    }
}
