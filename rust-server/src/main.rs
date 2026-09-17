//! The same SSE server, in Rust: axum on tokio.
//!
//! What this module is for: the JVM range runs from 148 KB of RSS per connection on Tomcat to 36 KB on
//! Netty, and Go answers how much of that is the JVM. Rust answers what is left when there is no
//! garbage collector at all — no heap to size, no collector threads, no metaspace.
//!
//! Everything that is not the language is copied from the servlet module: a 265-byte payload padded to
//! exactly that size, a 1 Hz tick composed ONCE per room, a bounded 256-deep queue per connection, and
//! a full queue closes the connection instead of growing. The stats endpoint publishes the same field
//! names on the same port so the same bench scripts read it.

use axum::{
    extract::{Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use futures::stream::StreamExt;
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicI64, AtomicU64, Ordering},
        Arc, RwLock,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::mpsc;

const FRAME_BYTES: usize = 265;
const QUEUE_DEPTH: usize = 256;

#[derive(Default)]
struct Stats {
    live: AtomicI64,
    connects: AtomicU64,
    disconnects: AtomicU64,
    frames: AtomicU64,
    dropped: AtomicU64,
    ticks: AtomicU64,
    fan_out_max_us: AtomicU64,
}

type Sender = mpsc::Sender<Arc<Vec<u8>>>;

struct Registry {
    rooms: RwLock<HashMap<String, Vec<(u64, Sender)>>>,
    next_id: AtomicU64,
    stats: Stats,
}

impl Registry {
    fn open(&self, room: &str) -> (u64, mpsc::Receiver<Arc<Vec<u8>>>) {
        let (tx, rx) = mpsc::channel(QUEUE_DEPTH);
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.rooms
            .write()
            .unwrap()
            .entry(room.to_string())
            .or_default()
            .push((id, tx));
        self.stats.live.fetch_add(1, Ordering::Relaxed);
        self.stats.connects.fetch_add(1, Ordering::Relaxed);
        (id, rx)
    }

    fn close(&self, room: &str, id: u64) {
        let mut rooms = self.rooms.write().unwrap();
        if let Some(members) = rooms.get_mut(room) {
            members.retain(|(mid, _)| *mid != id);
            if members.is_empty() {
                rooms.remove(room);
            }
        }
        self.stats.live.fetch_sub(1, Ordering::Relaxed);
        self.stats.disconnects.fetch_add(1, Ordering::Relaxed);
    }

    /// One frame per room per tick, handed to every session as a shared `Arc` — one allocation per
    /// room per second, not one per connection.
    fn tick(&self, seq: u64) {
        let start = Instant::now();
        let snapshot: Vec<(String, Vec<(u64, Sender)>)> = {
            let rooms = self.rooms.read().unwrap();
            rooms.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
        };
        for (room, members) in snapshot {
            if members.is_empty() {
                continue;
            }
            let wire = Arc::new(compose_frame(&room, seq));
            let mut dead = Vec::new();
            for (id, tx) in &members {
                match tx.try_send(wire.clone()) {
                    Ok(()) => {
                        self.stats.frames.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(mpsc::error::TrySendError::Full(_)) => {
                        // Bounded queue full: drop the session. Never buffer for an absent reader.
                        self.stats.dropped.fetch_add(1, Ordering::Relaxed);
                        dead.push(*id);
                    }
                    Err(mpsc::error::TrySendError::Closed(_)) => dead.push(*id),
                }
            }
            if !dead.is_empty() {
                let mut rooms = self.rooms.write().unwrap();
                if let Some(m) = rooms.get_mut(&room) {
                    m.retain(|(id, _)| !dead.contains(id));
                }
            }
        }
        let us = start.elapsed().as_micros() as u64;
        self.stats.ticks.fetch_add(1, Ordering::Relaxed);
        self.stats.fan_out_max_us.fetch_max(us, Ordering::Relaxed);
    }
}

/// Identical arithmetic to the Java and Go modules: the PAYLOAD is padded to exactly FRAME_BYTES,
/// so all four servers put the same number of bytes on the wire.
fn compose_frame(room: &str, seq: u64) -> Vec<u8> {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_micros() as u64;
    let head = format!(
        "{{\"type\":\"pool_update\",\"room\":\"{room}\",\"seq\":{seq},\"ts\":{ts},\
\"tiers\":[{{\"k\":\"mini\",\"a\":\"1234.56\"}},{{\"k\":\"minor\",\"a\":\"12345.67\"}},\
{{\"k\":\"major\",\"a\":\"123456.78\"}},{{\"k\":\"grand\",\"a\":\"1234567.89\"}}],\"cur\":\"TRY\",\"pad\":\""
    );
    let tail = "\"}";
    let pad = FRAME_BYTES.saturating_sub(head.len() + tail.len());
    let mut out = Vec::with_capacity(6 + FRAME_BYTES + 2);
    out.extend_from_slice(b"data:");
    out.extend_from_slice(head.as_bytes());
    out.extend(std::iter::repeat(b'x').take(pad));
    out.extend_from_slice(tail.as_bytes());
    out.extend_from_slice(b"\n\n");
    out
}

async fn stream(State(reg): State<Arc<Registry>>, Query(q): Query<HashMap<String, String>>) -> Response {
    let room = q.get("room").cloned().unwrap_or_else(|| "r0".to_string());
    let (id, rx) = reg.open(&room);
    let reg2 = reg.clone();
    let room2 = room.clone();

    let body = tokio_stream::wrappers::ReceiverStream::new(rx)
        .map(|wire| Ok::<_, std::io::Error>(axum::body::Bytes::copy_from_slice(&wire)))
        .chain(futures::stream::once(async move {
            reg2.close(&room2, id);
            Ok(axum::body::Bytes::new())
        }));

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .header("X-Accel-Buffering", "no")
        .body(axum::body::Body::from_stream(body))
        .unwrap()
}

fn rss_mb() -> f64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("VmRSS:"))
                .and_then(|l| l.split_whitespace().nth(1).and_then(|k| k.parse::<f64>().ok()))
        })
        .map(|kb| kb / 1024.0)
        .unwrap_or(-1.0)
}

fn open_fds() -> i64 {
    std::fs::read_dir("/proc/self/fd").map(|d| d.count() as i64).unwrap_or(-1)
}

async fn bench(State(reg): State<Arc<Registry>>) -> impl IntoResponse {
    let s = &reg.stats;
    let ticks = s.ticks.load(Ordering::Relaxed);
    // Same field names as the JVM and Go servers. ⚠ There is no heapLiveMb here and that is the point:
    // Rust has no garbage collector, so rssMb is the ONLY figure, and it is the one that compares
    // across all four runtimes anyway.
    let body = format!(
        r#"{{"liveSessions":{},"connectsAccepted":{},"disconnects":{},"framesWritten":{},"slowConsumerClosed":{},"ticksPublished":{},"fanOutMaxMillis":{:.3},"heapLiveMb":-1,"rssMb":{:.1},"platformThreads":{},"openFds":{},"queueDepth":{}}}"#,
        s.live.load(Ordering::Relaxed),
        s.connects.load(Ordering::Relaxed),
        s.disconnects.load(Ordering::Relaxed),
        s.frames.load(Ordering::Relaxed),
        s.dropped.load(Ordering::Relaxed),
        ticks,
        s.fan_out_max_us.load(Ordering::Relaxed) as f64 / 1000.0,
        rss_mb(),
        std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0),
        open_fds(),
        QUEUE_DEPTH
    );
    ([(header::CONTENT_TYPE, "application/json")], body)
}

#[tokio::main]
async fn main() {
    let reg = Arc::new(Registry {
        rooms: RwLock::new(HashMap::new()),
        next_id: AtomicU64::new(0),
        stats: Stats::default(),
    });

    let interval: u64 = std::env::var("TICK_INTERVAL_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1000);

    let tick_reg = reg.clone();
    tokio::spawn(async move {
        let mut t = tokio::time::interval(Duration::from_millis(interval));
        t.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut seq = 0u64;
        loop {
            t.tick().await;
            seq += 1;
            let r = tick_reg.clone();
            // The fan-out is CPU work on a lot of channels; keeping it off the async worker that owns
            // the timer is the same reason the Java modules put the tick on its own platform thread.
            tokio::task::spawn_blocking(move || r.tick(seq)).await.ok();
        }
    });

    let stats_reg = reg.clone();
    tokio::spawn(async move {
        let app = Router::new()
            .route("/actuator/health", get(|| async { r#"{"status":"UP"}"# }))
            .route("/actuator/bench", get(bench))
            .with_state(stats_reg);
        let l = tokio::net::TcpListener::bind("0.0.0.0:9090").await.unwrap();
        axum::serve(l, app).await.unwrap();
    });

    let app = Router::new().route("/sse/stream", get(stream)).with_state(reg);
    let l = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    axum::serve(l, app).await.unwrap();
}
