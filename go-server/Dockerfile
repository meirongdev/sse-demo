FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /sse-go .

FROM alpine:3.21
COPY --from=build /sse-go /sse-go
EXPOSE 8080 9090
ENTRYPOINT ["/sse-go"]
