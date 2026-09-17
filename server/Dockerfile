# The jar is built on the host by `make build` — the toolchain is already there (JDK 25, Maven 3.9)
# and a build stage here would re-resolve the Boot 4 dependency tree on every image rebuild for
# nothing. The image carries a JRE and the jar, and that is all a connection tier needs.
FROM eclipse-temurin:25-jre

WORKDIR /app
COPY target/sse-vs-ws-server-1.0.0-SNAPSHOT.jar app.jar

# ⚠ MaxRAMPercentage, not Xmx, and 70 rather than 75. In an 8 GB cgroup the heap is NOT the whole
# story at this connection count: thread stacks, Tomcat's NIO buffers, the kernel-visible socket
# memory and metaspace all come out of the same limit, and the cgroup kills the process on RSS.
# The 30% left over is what stops a heap that fits from becoming a container that does not.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -Djava.net.preferIPv4Stack=true"

EXPOSE 8080 9090
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
