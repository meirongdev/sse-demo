package com.meirongdev.ssedemo.ws;

import com.meirongdev.ssedemo.core.Registry;
import com.meirongdev.ssedemo.core.Session;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

/** {@code GET /ws/stream?room=} — one WebSocket per connection, onto the same registry the SSE path uses. */
@Component
public class WsHandler extends TextWebSocketHandler {

    /**
     * ⚠ <b>Tomcat's {@code WsSession} is handed to the handler, and the registry's {@link Session} is ours.</b>
     * The close arrives on the first and has to reach the second, so the pairing is held here. It is a
     * per-connection map entry — tens of bytes — and it is the one structural cost this harness pays on the
     * WebSocket side that the SSE side does not, because {@code SseEmitter} takes a completion callback and
     * {@code WebSocketHandler} does not.
     */
    private final Map<String, Session> sessions = new ConcurrentHashMap<>();

    private final Registry registry;
    private final boolean preEncoded;

    public WsHandler(Registry registry, @Value("${demo.encode:text}") String encode) {
        this.registry = registry;
        this.preEncoded = "bytes".equalsIgnoreCase(encode);
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession wsSession) throws Exception {
        String room = room(wsSession);
        Session session = registry.open(room, new WsSink(wsSession, preEncoded));
        if (session == null) {
            wsSession.close(CloseStatus.SERVICE_OVERLOAD);
            return;
        }
        sessions.put(wsSession.getId(), session);
    }

    @Override
    public void afterConnectionClosed(WebSocketSession wsSession, CloseStatus status) {
        Session session = sessions.remove(wsSession.getId());
        if (session != null) {
            session.close(false);
        }
    }

    private static String room(WebSocketSession wsSession) {
        String query = wsSession.getUri() == null ? null : wsSession.getUri().getQuery();
        if (query != null) {
            for (String pair : query.split("&")) {
                if (pair.startsWith("room=")) {
                    return pair.substring(5);
                }
            }
        }
        return "r0";
    }
}
