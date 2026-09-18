package com.meirongdev.ssedemo.config;

import org.apache.catalina.connector.Connector;
import org.apache.coyote.UpgradeProtocol;
import org.apache.coyote.http2.Http2Protocol;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.tomcat.TomcatConnectorCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * The two NIO socket buffers Spring exposes no property for, opened up so the SSE side can be tuned the way the
 * WebSocket side already can.
 *
 * <p><b>Why this exists.</b> An SSE connection is an HTTP request that never completes, so Tomcat's
 * {@code Http11Processor} and its {@code NioSocketWrapper} stay alive for the life of the connection — and with
 * them a read buffer and a write buffer of {@code socket.appReadBufSize} / {@code socket.appWriteBufSize}, 8192
 * bytes each by default. <b>A WebSocket sheds the processor at upgrade; an SSE stream never does.</b> That is the
 * structural reason SSE measured 110 KB per connection against WebSocket's 37 KB, and these are the knobs that
 * test how much of it is recoverable.
 *
 * <p>⚠ <b>Both transports ride the same NIO connector</b>, so lowering these helps WebSocket too — only the
 * header buffers behind {@code server.max-http-request-header-size} are SSE-specific in effect. A run that
 * changes these and compares SSE against a WebSocket baseline taken at the OLD setting would credit SSE with a
 * saving both transports got.
 *
 * <p>Defaults are Tomcat's own, so this bean changes nothing until a run asks it to.
 */
@Configuration
public class TomcatTuning {

    /**
     * HTTP/2's stream ceiling, which decides whether an h2 run measures multiplexing at all.
     *
     * <p>⚠ <b>Tomcat's default is 100 concurrent streams per connection.</b> Left alone, 20,000 streams would
     * open 200 TCP connections and the run would measure HTTP/1.1 with extra steps — the per-connection object
     * graph this benchmark is about would be paid 200 times instead of once. Raising it is what makes the
     * question "what does a STREAM cost" answerable.
     */
    @Bean
    public TomcatConnectorCustomizer http2Customizer(
            @Value("${demo.tomcat.max-concurrent-streams:100}") int maxStreams) {
        return (Connector connector) -> {
            for (UpgradeProtocol protocol : connector.findUpgradeProtocols()) {
                if (protocol instanceof Http2Protocol http2) {
                    http2.setMaxConcurrentStreams(maxStreams);
                    http2.setMaxConcurrentStreamExecution(maxStreams);
                }
            }
        };
    }

    @Bean
    public TomcatConnectorCustomizer socketBufferCustomizer(
            @Value("${demo.tomcat.app-read-buf-size:8192}") int readBufSize,
            @Value("${demo.tomcat.app-write-buf-size:8192}") int writeBufSize,
            @Value("${demo.tomcat.direct-buffer:true}") boolean directBuffer) {
        return (Connector connector) -> {
            connector.setProperty("socket.appReadBufSize", Integer.toString(readBufSize));
            connector.setProperty("socket.appWriteBufSize", Integer.toString(writeBufSize));
            // ⚠ `socket.*` routes to SocketProperties, not to the endpoint — which is why this works the
            // same way appReadBufSize does. Tomcat 11 removed AbstractEndpoint's own direct-buffer
            // accessors, but SocketProperties.setDirectBuffer(boolean) is still there.
            //
            // This does NOT shrink the buffers, it relocates them: same bytes resident, off the Java
            // heap. That targets the wall RESULTS §2 measured — heap OOM at ~52,000 while RSS was only
            // at 74% of the cgroup — at the price of charging them to MaxDirectMemorySize instead.
            connector.setProperty("socket.directBuffer", Boolean.toString(directBuffer));
            // Printed because nothing else can confirm it: the value is not visible on /actuator/bench,
            // and 缺陷 11 is exactly the class of bug where a knob is set and silently does nothing.
            System.out.println("TomcatTuning: socket.directBuffer=" + directBuffer
                    + " appReadBufSize=" + readBufSize + " appWriteBufSize=" + writeBufSize);
        };
    }
}
