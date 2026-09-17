package com.meirongdev.ssedemo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * SSE and WebSocket, one process, one fan-out core, one set of frame bytes.
 *
 * <p>The question this exists to answer: <b>on 4 vCPU and 8 GB, how many long-lived connections does each
 * transport hold while delivering the same 1 Hz push?</b> Running both in the same JVM is what makes the answer
 * a statement about the transports — a second process would have brought its own heap, its own GC and its own
 * container, and any difference could have come from those instead.
 */
@SpringBootApplication
public class DemoApplication {

    public static void main(String[] args) {
        SpringApplication.run(DemoApplication.class, args);
    }
}
