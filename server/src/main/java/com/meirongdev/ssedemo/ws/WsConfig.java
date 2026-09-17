package com.meirongdev.ssedemo.ws;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;
import org.springframework.web.socket.server.standard.ServletServerContainerFactoryBean;

/**
 * Registers {@code /ws/stream}, and exposes the two knobs that decide WebSocket's per-connection heap.
 *
 * <p>⚠ <b>This is the WebSocket side's equivalent of Tomcat's 8,192 {@code maxConnections} default — a number
 * that is fine at a hundred connections and decides the answer at fifty thousand.</b> Tomcat allocates the
 * incoming message buffers <b>eagerly, per session</b>: a {@code ByteBuffer} of {@code maxBinaryMessageBufferSize}
 * and a {@code CharBuffer} of {@code maxTextMessageBufferSize} — and a {@code char} is two bytes, so the text
 * buffer costs twice its setting. At the 8,192 default that is ~24 KB of heap per connection <b>before any frame
 * is sent</b>, and this service's clients send nothing at all.
 *
 * <p>Both default to 1,024 here and the benchmark runs {@code default} and {@code tuned} passes, because the
 * honest answer to "how many connections" is two numbers: what the stack gives you untouched, and what it gives
 * you once you have found this.
 */
@Configuration
@EnableWebSocket
public class WsConfig implements WebSocketConfigurer {

    private final WsHandler handler;
    private final int textBufferSize;
    private final int binaryBufferSize;

    public WsConfig(
            WsHandler handler,
            @Value("${demo.ws.text-buffer-size:1024}") int textBufferSize,
            @Value("${demo.ws.binary-buffer-size:1024}") int binaryBufferSize) {
        this.handler = handler;
        this.textBufferSize = textBufferSize;
        this.binaryBufferSize = binaryBufferSize;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(handler, "/ws/stream").setAllowedOrigins("*");
    }

    @Bean
    public ServletServerContainerFactoryBean webSocketContainer() {
        ServletServerContainerFactoryBean container = new ServletServerContainerFactoryBean();
        container.setMaxTextMessageBufferSize(textBufferSize);
        container.setMaxBinaryMessageBufferSize(binaryBufferSize);
        // No idle timeout. The connection's lifetime is the session's, exactly as on the SSE side — an asymmetry
        // here would be measured as a difference between the transports.
        container.setMaxSessionIdleTimeout(0L);
        return container;
    }
}
