FROM eclipse-temurin:25-jre
WORKDIR /app
COPY target/sse-vs-ws-webflux-1.0.0-SNAPSHOT.jar app.jar
# Identical to the servlet module's, so the JVM is not a variable either.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -Djava.net.preferIPv4Stack=true"
EXPOSE 8080 9090
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
