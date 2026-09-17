# 已测结果

环境：OrbStack 容器，服务端固定 4 vCPU / 8 GB cgroup 限额，265 字节帧 @ 1 Hz，队列深度 256。
全部原始数据见 `results/ALL-RUNS.csv`。

⚠ **单机 OrbStack，非真机。** 按参考项目 `CLAUDE.md` 自身标准
（*"a benchmark is unmeasured until it runs on a real node, not a laptop"*），
**这批数不能作为 benchmark of record 引用**，只作方向性结论。

---

## 1. 核心结论：容器的选择比 transport 的选择影响更大

**SSE @ 20,000，每客户端一条连接**，`heapLive` 口径：

| 栈 | 每连接 | 相对 Tomcat |
|---|---|---|
| Tomcat（全调优） | 88.3 KB | — |
| **Jetty**（Spring MVC 不变） | **17.6 KB** | **5.0×** |
| WebFlux / Netty | 19.5 KB | 4.5× |

**SSE + Jetty（17.6 KB）比 WebSocket + Tomcat（37.9 KB）还便宜一倍。**
换容器改一行 `pom.xml`，换 transport 要改客户端契约。

### SSE 与 WS 的排序**随容器翻转**

| 每连接 @ 20,000 | SSE | WebSocket | 关系 |
|---|---|---|---|
| Tomcat（各自全调优） | 88.3 KB | 37.9 KB | SSE 贵 **2.3×** |
| **Jetty** | **17.6 KB** | 20.9 KB | **SSE 便宜 16%** |
| WebFlux / Netty | 19.5 KB | 10.4 KB | SSE 贵 1.9× |

**「SSE 比 WebSocket 开销大」不是 transport 的属性。** 在 Tomcat 和 Netty 上成立，在 Jetty 上不成立。

---

## 2. Tomcat 内部：SSE vs WebSocket

20,000 用户，每人一条连接（已核实 `openFds` 全部 = 20,018）：

| 配置 | 存活堆 | 每用户 | p99 |
|---|---|---|---|
| SSE / HTTP2，每连接 1 条流 | 3356 MB | 168 KB | —（压测端饱和作废） |
| SSE / HTTP1.1 | 2284 MB | 113 KB | 328 ms |
| SSE / HTTP1.1 全调优 | 1799 MB | 88 KB | 164 ms |
| WS，Tomcat 默认缓冲 | 1605 MB | 78 KB | 131 ms |
| WS，Spring knob → 1 KB | 1175 MB | 56 KB | 229 ms |
| **WS 全调优** | **815 MB** | **37 KB** | **115 ms** |

**WebSocket 一行配置都不改（78 KB），已经比 SSE 调到最优（88 KB）还便宜。**

### 单机上限阶梯（Tomcat，`maxConnections=200000`）

| 档位 | SSE p99 | 判定 | WS p99 | 判定 |
|---|---|---|---|---|
| 10,000 | 164 ms | PASS | 131 ms | PASS |
| 20,000 | 328 ms | PASS | 229 ms | PASS |
| 40,000 | 6291 ms | **FAIL** | 524 ms | PASS |
| 60,000 | — | — | 4194 ms | **FAIL** |

调优后 SSE 上限移到 **30,000**（40,000 仍 FAIL，但 CPU 只用 133%——见下）。

---

## 3. 崩溃机制：分两个 regime

| SSE @ 40,000 | 缓冲未调 | 缓冲已调 |
|---|---|---|
| 存活堆 | 4494 MB | 3550 MB |
| 堆占用率（上限 5736 MB） | 78% | 62% |
| CPU 中位 | **400%**（钉死） | **133%**（余量 267%） |
| fanOut 峰值 | 2575 ms | 968 ms |

- **regime A（内存压力大）**：GC 并发工作吃满 CPU → 单线程扇出被饿死
- **regime B（压力解除）**：**扇出线程自身吞吐成为上限** —— 一条线程约 4 万次 enqueue/秒，加内存加 CPU 都没用

### 分片扇出：有效，但只在它该有效的地方

| 对照 | 分片 | fanOut 峰值 | p99 |
|---|---|---|---|
| SSE @ 40,000 | 1 | 469 ms | 655 ms |
| SSE @ 40,000 | 4 | **117 ms** | **459 ms** |
| WS @ 60,000 | 1 | 126 ms | 393 ms |
| WS @ 60,000 | 4 | 148 ms | 393 ms |

SSE 那组 **fanOut 降到 1/4，正好等于分片数**；WS 那组本来就只有 126 ms，扇出不是瓶颈，分片后无变化。
**这个阴性对照比阳性那半更有说服力。**

**判断是否该上分片：看 `fanOutMaxMillis` 是否逼近 tick 周期，不是看连接数。**

---

## 4. 每连接的钱花在哪（profiling）

堆直方图差分（空载 vs 满载，`GC.class_histogram` 强制 full GC）：

| 每连接实例数 | SSE | WebSocket |
|---|---|---|
| `MessageBytes` | 41 | 0 |
| `ByteChunk` | 45 | 0 |
| `CharChunk` | 42 | 0 |
| `MimeHeaderField` / `MimeHeaders` | 11 / 3 | 0 |
| `coyote.Request` / `Response` | 1 / 1 | 0 |
| `Http11Processor` / `Http11InputBuffer` | 1 / 1 | 0 |
| `WsSession` / `WsFrameServer` / `WsRemoteEndpointImplServer` | 0 | 1 / 1 / 1 |
| **合计** | **111.9 KB** | **56.1 KB** |

⚠ **这些是 Tomcat 的内部表示，不是 servlet 规范要求的** —— Jetty 用完全不同的实现满足同一套语义。

最大单项：4 个约 8 KB 的 char 数组（32.9 KB/连接），**缓冲调优的两个旋钮都没动到它**。

### CPU（JFR，60s 稳态 @ 20,000）

| | SSE | WS |
|---|---|---|
| CPU 采样 | 749 | 414 |
| 分配采样 | 1695 | 933 |
| `SocketWrite` | 358 | 309 |

`SocketWrite` 几乎相同（同一批帧），但 SSE 的 CPU 和分配都是 **1.8 倍**。分配热点前三名
`toLowerCase` 29% + `encodeUTF8` 12% + `parseMediaType` 10% = **51%，全在每次 `send()` 上**。

---

## 5. Tomcat 的两类可调项

### WebSocket 每连接缓冲（`WsFrameBase` 构造函数，建连时一次性分配）

| 缓冲 | 默认 | 谁能改 |
|---|---|---|
| `controlBufferBinary` / `Text` | 125 B / 250 B | 固定 |
| `inputBuffer` | 8192 B | 仅系统属性 `org.apache.tomcat.websocket.DEFAULT_BUFFER_SIZE` |
| `messageBufferBinary` | 8192 B | Spring knob |
| `messageBufferText` | 16384 B | Spring knob（**char 翻倍**） |
| **合计** | **33.1 KB** | 调完 5.5 KB |

实测三档（20,000）：默认 76 KB → Spring knob 56 KB → 加系统属性 **37 KB**。
第一步省下 21.5 KB/连接，**与字节码算出的 33.1−11.6 = 21.5 KB 精确吻合**。

### SSE 的三个旋钮

| 配置 | 每连接 | CPU 中位 |
|---|---|---|
| 基线 | 111.8 KB | 57% |
| `max-http-request-header-size` 8→2 KB | 106 KB | 53% |
| 再加两个 NIO socket 缓冲 → 2 KB | **88.3 KB** | **48%** |

⚠ **23.5 KB 里只有 5.8 KB 是 SSE 独得的**；另外 17.7 KB 来自 socket 缓冲，**WebSocket 同样受益**。

---

## 6. HTTP/2：取决于一个用户开几条流

**20,000 条 SSE 流**：

| 配置 | TCP 连接 | 存活堆 | 每用户 |
|---|---|---|---|
| h2，每连接 1 条流（独立用户） | 20,018 | 3356 MB | **168 KB** |
| h2，每连接 3 条流 | 6,685 | 2003 MB | 98 KB |
| h2，每连接 6 条流 | 3,352 | 1705 MB | 82 KB |
| h2，共享 transport（**上界，非流量模型**） | 19 | 1449 MB | 72 KB |
| HTTP/1.1 对照 | 20,018 | 2284 MB | 110 KB |

**成本模型**（两点解出，第三点证伪）：

```
h2 每用户 = 99 KB ÷ 每连接流数 + 65 KB
```

跑前落盘预测 spc=3 → **2030 MB**，实测 **2003 MB**，偏差 **−1.3%**。
spc=1@10k 独立验证：预测 164 KB，实测 161 KB。

**盈亏平衡 n ≳ 2.2 条流/连接。** 一个用户 1 条流时 h2 **贵 46%** 且延迟无改善
（10k 干净重测：h2 与 h1.1 的 p99 都是 163.84 ms）。

**给 SSE 上 HTTP/2 的价值不在内存，是消除浏览器每源 6 连接限制——那是功能问题。**

---

## 7. 预编码（`ENCODE=bytes`）

| JFR @ 20,000 | text | bytes |
|---|---|---|
| **CPU 采样** | 749 | **604（−19%）** |
| `String.encodeUTF8` | 11.9% | **1.9%** |
| `StringLatin1.toLowerCase` | 29.0% | 32.4% |
| `MediaType.parseMediaType` | 10.1% | 9.1% |

**值 19% 的 CPU，但只打掉一半** —— `toLowerCase` + `parseMediaType` 那约 40% 是 Spring 每次
`send()` 的 media type 协商，与载荷类型无关。20,000 连接时 CPU 仅 57%，不是瓶颈，所以 p99 看不出来。

---

## 8. 五种运行时（**RSS 口径**）

| SSE @ 20,000 | 空载 RSS | 负载 RSS | 每连接 RSS | p99 | fanOutMax |
|---|---|---|---|---|---|
| Java · Tomcat（全调优） | 294 MB | 3187 MB | **148.1 KB** | 164 ms | 81 ms |
| Java · Jetty | 272 MB | 1526 MB | **64.2 KB** | 164 ms | 62 ms |
| Java · Netty（WebFlux） | 263 MB | 966 MB | **36.0 KB** | 131 ms | 103 ms |
| Go · net/http | **6.6 MB** | 732 MB | **37.1 KB** | 115 ms | 123 ms |
| Rust · axum/tokio | **1.1 MB** | 680 MB | **34.7 KB** | 115 ms | **47 ms** |

**Netty 36.0、Go 37.1、Rust 34.7 —— 相差 7% 以内。** 有 GC 的 JVM、有 GC 的 Go、
无 GC 的 Rust 落在同一量级，说明这 ~35 KB 主要是**每连接 I/O 缓冲，谁都躲不掉**。

**「换 Rust 省内存」在斜率上不成立。** 数量级差距只剩空载基线（263 MB vs 1.1 MB），而它是固定成本：

| 连接数 | JVM 基线折合每连接 |
|---|---|
| 1,000 | 262 KB（压倒性） |
| 10,000 | 26 KB（同量级） |
| 100,000 | 2.6 KB（可忽略） |

**JVM 的问题不是「JVM 重」，是「选了 Tomcat」：148 → 36 KB 是 4 倍，换容器就能拿回；换语言只值 7%。**

不对等声明：Go / Rust 是最小实现（无鉴权、tracing、优雅停机）；Go 的 `chan []byte` 环形缓冲
（256×24 B = 6 KB/连接）比对手贵约 4 KB；Rust 用 axum 而非裸 socket 是刻意的。

---

## 9. 上限阶梯（**未完成**）

`bench/ceiling.sh` 跑到一半被中止，已完成部分：

| 运行时 | 40,000 | 60,000 | 80,000 | 100,000 |
|---|---|---|---|---|
| **Rust** | ✅ PASS | ✅ PASS | 未测 | 未测 |
| Go | 未测 | 未测 | 未测 | 未测 |
| Netty | 未测 | 未测 | 未测 | 未测 |

Rust @ 40,000 的 RSS 严格线性（34.7 KB/连接，与 20,000 档一致），`fanOutMax` 仅 **36.5 ms**
（20,000 档是 47 ms，**几乎不随连接数增长**），距 1 秒 tick 周期有 27 倍余量。

**纯内存上限估算**（8 GB 容器，按实测每连接 RSS）：Tomcat ~53,000；Netty / Go / Rust ~22 万。
⚠ **内存几乎肯定不是实际瓶颈**，实测上限会低得多。这一节是下次要补完的第一项。

---

## 10. 撞墙顺序（与 transport 无关）

| 墙 | 默认 | 症状 |
|---|---|---|
| Tomcat `maxConnections` | **8192** | **静默**停止 accept：要 12,000 拿到 8,192，`failed=0 rejected=0` |
| WS 每连接缓冲 | 33 KB | 仅 WS |
| accept backlog | 100 | 高速 ramp 被拒 |
| 文件描述符 | 1024 | `Too many open files` |
| 压测端临时端口 | ~28 K | **长得像服务端到顶** |
| 单线程扇出 | — | p99 随连接数跃升 |

⚠ **虚拟线程不抬高连接上限。** `maxConnections` 是 NIO connector 上的计数器，与 executor 无关。
已用内核级证据确认虚拟线程生效：5,000 连接时 OS 线程仅 40 个，`http-nio-8080-exec-N` **为零**。
