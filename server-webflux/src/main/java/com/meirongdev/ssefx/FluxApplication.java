package com.meirongdev.ssefx;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * The same experiment on Netty.
 *
 * <p>The profiler found SSE's cost on the servlet stack to be Tomcat's own: 41 {@code MessageBytes},
 * 45 {@code ByteChunk}, 42 {@code CharChunk} and a whole {@code Http11Processor} held per connection,
 * because an SSE stream is an HTTP request that never completes. <b>None of those types exist here.</b>
 * Whether that translates into a cheaper connection is the only question this module asks.
 */
@SpringBootApplication
public class FluxApplication {
    public static void main(String[] args) {
        SpringApplication.run(FluxApplication.class, args);
    }
}
