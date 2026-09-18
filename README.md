# SSE vs WebSocket 容量基准

同一套推送功能，在 **5 种运行时 × 3 种 transport** 下测「4C8G 能扛多少长连接」。

📄 **报告**：https://claude.ai/artifact/Lun5BgzKXDzEiYZUxhqF3H

| 文档 | 内容 |
|---|---|
| [`docs/PLAN.md`](docs/PLAN.md) | **压测计划** —— 前置条件、执行顺序、参数、判定标准、移到真机前要改什么 |
| [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md) | **方法与坑** —— 指标怎么选、harness 的 8 个缺陷（已全部修掉）、哪些数字不可信 |
| [`docs/RESULTS.md`](docs/RESULTS.md) | **已测结果** —— 全部结论与原始数字 |
| `results/ALL-RUNS.csv` | 64 次 run 的汇总（`python3 bench/collect.py` 重新生成） |

---

## 最快上手

```bash
make build      # 打 jar、构建全部镜像（需 JDK 25 / Maven / Go / Rust）
make smoke      # 200 连接 20 秒：先证明 harness 可信，再谈结果
bench/sweep.sh  # 主矩阵，约 30 分钟
python3 bench/collect.py   # 汇总成 results/ALL-RUNS.csv
```

单次运行，全部参数都是环境变量：

```bash
MODE=sse CONNS=40000 CLIENTS=2 RATE=4000 HOLD=120s \
  SERVER_IMAGE=ssebench-jetty LABEL=my-run bench/run.sh
```

---

## 三个最重要的结论

**1. 容器的选择比 transport 的选择影响更大。**
SSE 每连接：Tomcat 88 KB → **Jetty 17.6 KB**（5 倍）。
**SSE + Jetty 比 WebSocket + Tomcat 还便宜一倍** —— 换容器改一行 pom，换 transport 要改客户端契约。
⚠ 那个 17.6 KB 是**存活堆**；Jetty 的每连接 **RSS ≈64 KB，是四条路径里最贵的**（§9 结论 5）。
按内存选型必须看 RSS，只看堆会把最费内存的运行时选成最省的。

**2.「SSE 比 WebSocket 贵」不是 transport 的属性，它随容器翻转。**
Tomcat 上 SSE 贵 2.3×，**Jetty 上 SSE 便宜 16%**，Netty 上 SSE 贵 1.9×。

**3. 换语言只值 7%。**
每连接 RSS：Netty 36.0 / Go 37.1 / Rust 34.7 KB —— 三者相差 7% 以内。
数量级差距只剩空载基线（263 MB vs 1.1 MB），而它是固定成本，10 万连接时只折合 2.6 KB/连接。

---

## 组成

| 目录 | 是什么 |
|---|---|
| `server/` | Spring Boot 4 · Java 25 · 虚拟线程 · Tomcat。SSE 与 WS 在**同一进程**，共用帧、注册表、有界队列 |
| `server-jetty/` | 同一份源码（`sourceDirectory` 指向 `server/`，**不是拷贝**），只换 Jetty |
| `server-webflux/` | WebFlux / Netty，reactive 模型 |
| `go-server/` · `rust-server/` | Go（stdlib）与 Rust（axum/tokio）的等价实现 |
| `loadgen/` | Go 压测端：HTTP/1.1 手写零依赖，h2 用 `x/net/http2` |
| `bench/` | 全部脚本，见 `docs/PLAN.md` |

---

## 必读的两条

⚠ **严格串行。** `run.sh` 与 `profile.sh` 共用 `/tmp/ssebench.lock`。并发执行会互删容器并**静默**产出空结果。
锁由 `bench/benchlock.sh` 持有到进程退出（曾经只守得住启动那几毫秒，见 METHODOLOGY 缺陷 7）；
第二个 run 会看到 owner pid 并以 3 退出 —— 它**只拒绝，不排队**。

⚠ **压测端饱和的 run 作废。** 每次运行自动打印各容器 CPU 峰值；任一 client 接近自身上限即不作数 ——
服务端读数此时看着仍很从容，只看服务端会误判成服务端到顶。本轮已有 3 个 p99 因此作废。

---

## 这批数字的效力边界

跑在单机 OrbStack 容器里，**不是真机**。容器是真 Linux 内核 + 真 cgroup 限额，方向性结论可信；
但按参考项目 `CLAUDE.md` 自身标准（*"a benchmark is unmeasured until it runs on a real node,
not a laptop"*），**不能作为 benchmark of record 引用**。

未测：TLS、网关/LB、重连风暴、Jetty 自身的容器调优、Go/Rust 的生产特性（鉴权/tracing/优雅停机）。
上限阶梯（`bench/ceiling.sh`）已跑完 rust / go / netty × 40k–100k，**12/12 全 PASS**——
但 100k 是**这台机器测到的最高一档，不是上限**（服务端 CPU 最高 264%/400%，最紧的判据 p99 524 ms 距 1 s 还有一倍）。
**Jetty 另跑六档：20k–80k 全 PASS，100k FAIL**（p99 1049 ms，超判据 4.9%，4 个 vCPU 打满 400%）——
按 §6 的教训读成 **8–10 万区间**，不是 80,000 这个点值。
**Tomcat 仍不在这条阶梯上**，四条曲线的真临界点都未测。
WS 阶梯（`MODE=ws bench/ceiling.sh`）：**Netty 40k–100k 全 PASS**，100k 档 p99 459 ms、24.9 KB/连接，
比同档 SSE 省 39% RSS、扇出耗时少一半。**Go 与 Rust 的服务端没有实现 `/ws/stream`**（只注册了
`/sse/stream`），`MODE=ws` 打过去是 **404、建连 0** —— 那是功能缺失，不是容量结论（§9b、缺陷 8）。
