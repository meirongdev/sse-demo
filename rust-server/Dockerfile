FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release && strip target/release/sse-rust

FROM alpine:3.21
COPY --from=build /src/target/release/sse-rust /sse-rust
EXPOSE 8080 9090
ENTRYPOINT ["/sse-rust"]
