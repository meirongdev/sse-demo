FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
# Vendored, so the image build needs no network and the h2 client's dependency is pinned in the repo.
# The HTTP/1.1 paths still have no dependencies — x/net/http2 is only on the h2 path, and reimplementing
# HPACK and h2 flow control to keep the zero-dependency property would have been the wrong trade.
COPY vendor ./vendor
COPY *.go ./
RUN CGO_ENABLED=0 go build -mod=vendor -ldflags="-s -w" -o /loadgen .

FROM alpine:3.21
COPY --from=build /loadgen /loadgen
ENTRYPOINT ["/loadgen"]
