.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

help: ## list every target
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: build-java build-go build-rust build-loadgen ## build every image (see docs/PLAN.md for toolchain)

build-java: ## the three JVM servers: Tomcat, Jetty, Netty
	cd server && mvn -q -B -DskipTests package
	cd server-jetty && mvn -q -B -DskipTests package
	cd server-webflux && mvn -q -B -DskipTests package
	docker build -q -t ssebench-server  server
	docker build -q -t ssebench-jetty   server-jetty
	docker build -q -t ssebench-webflux server-webflux
	docker build -q -t ssebench-server-prof -f server/Dockerfile.prof server

build-go: ## the Go server
	docker build -q -t ssebench-go go-server

build-rust: ## the Rust server
	docker build -q -t ssebench-rust rust-server

build-loadgen: ## the load generator
	docker build -q -t ssebench-loadgen loadgen

images: ## show what is built
	@docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep ssebench | sort || echo "(none built)"

smoke: ## 200 connections, 20s — proves the harness before it is trusted with a ceiling
	MODE=sse CONNS=200 CLIENTS=1 RATE=200 HOLD=20s LABEL=smoke-sse bench/run.sh
	MODE=ws  CONNS=200 CLIENTS=1 RATE=200 HOLD=20s LABEL=smoke-ws  bench/run.sh

sweep: ## the main matrix: both transports, default and tuned, ramped to the ceiling
	bench/sweep.sh

ceiling: ## how many users per box, one connection each — the unfinished one
	bench/ceiling.sh rust:ssebench-rust go:ssebench-go netty:ssebench-webflux

collect: ## fold every run into results/ALL-RUNS.csv
	python3 bench/collect.py

report: ## print every completed run as one table
	bench/report.sh

clean: ## remove containers, network and the lock
	-docker rm -f $$(docker ps -aq --filter name=ssebench --filter name=sseprof --filter name=pgbase) 2>/dev/null
	-docker network rm ssebench 2>/dev/null
	-rmdir /tmp/ssebench.lock 2>/dev/null

clean-images: ## also remove the built images
	-docker rmi ssebench-server ssebench-jetty ssebench-webflux ssebench-server-prof ssebench-go ssebench-rust ssebench-loadgen 2>/dev/null

.PHONY: help build build-java build-go build-rust build-loadgen images smoke sweep ceiling collect report clean clean-images
