# 压测计划

在另一台机器上复现这套基准的执行顺序。每一阶段回答一个问题，**顺序有意义**——后面的阶段要用前面的结论作为口径。

---

## 0. 前置条件

| 必需 | 用途 |
|---|---|
| Docker（**Linux 容器**，非 Docker Desktop for Mac 的 vpnkit 网络） | 服务端与压测端容器 |
| `jq` · `python3` · `make` · `bash` | 脚本与汇总 |

| 仅重建镜像时需要 | |
|---|---|
| JDK 25 + Maven 3.9 | `server` / `server-jetty` / `server-webflux` |
| Go 1.25+ | `loadgen` / `go-server` |
| Rust 1.90+ | `rust-server` |

**宿主机要求**：服务端容器固定 4 vCPU / 8 GB，压测端每 20,000 连接需 1 个容器（1 CPU / 2 GB），
所以 10 万连接约需 `4 + 5 = 9` 核。**核数不足时压测端会先于服务端饱和，该档数据作废。**

```bash
make build      # 打 jar、构建全部镜像
make smoke      # 200 连接 20 秒，先证明 harness 可信再谈结果
```

---

## 1. 阶段与执行顺序

| # | 脚本 | 回答什么 | 时长 |
|---|---|---|---|
| 1 | `make smoke` | harness 本身是否可信（双 transport 投递率必须 = 1.0） | 2 min |
| 2 | `bench/sweep.sh` | Tomcat 默认值的墙在哪；SSE / WS 各自的单机上限阶梯 | ~30 min |
| 3 | `bench/sse-tuning.sh` | SSE 的三个缓冲旋钮各值多少 | ~10 min |
| 4 | `bench/fanout.sh` | 分片扇出是否有效、在什么条件下有效 | ~12 min |
| 5 | `bench/profile.sh` | 每连接的内存/CPU 具体花在哪（堆直方图 + NMT + JFR） | ~5 min/次 |
| 6 | `bench/h2-realistic.sh` | HTTP/2 在真实客户端分布下的成本 | ~10 min |
| 7 | `bench/encode.sh` + `bench/verify-bytes.sh` | 预编码值多少 CPU | ~15 min |
| 8 | `bench/jetty.sh` · `bench/webflux.sh` | 换容器 / 换编程模型各贡献多少 | ~12 min |
| 9 | `bench/polyglot.sh` | Go / Rust 的每连接成本 | ~10 min |
| 10 | `bench/ceiling.sh <name>:<image> …` | **每用户一连接时的实测上限** | ~40 min |
| — | `python3 bench/collect.py` | 把全部 run 汇总成 `results/ALL-RUNS.csv` | 秒级 |

⚠ **严格串行。** `run.sh` 与 `profile.sh` 共用 `/tmp/ssebench.lock`；并发执行会互删容器
并静默产出空结果（METHODOLOGY 缺陷 1 / 7）。

---

## 2. 单次运行

所有参数都是环境变量：

```bash
MODE=ws CONNS=40000 CLIENTS=2 RATE=4000 HOLD=120s \
  MAX_CONNECTIONS=200000 WS_TEXT_BUFFER=1024 WS_BINARY_BUFFER=1024 \
  LABEL=my-run bench/run.sh
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `MODE` | `sse` | `sse` · `ws` · `sse-h2` |
| `CONNS` / `CLIENTS` / `RATE` | 20000 / 2 / 2000 | 总连接数、压测容器数、连接/秒 |
| `HOLD` | 120s | 满载保持时长 |
| `STREAMS_PER_CONN` | 1 | 仅 `sse-h2`：每 TCP 连接承载几条流 |
| `SERVER_IMAGE` | `ssebench-server` | `ssebench-jetty` · `ssebench-webflux` · `ssebench-go` · `ssebench-rust` |
| `CPUS` / `MEM` | 4 / 8g | 被测机器规格 |
| `MAX_CONNECTIONS` | 8192 | ⚠ Tomcat 默认值，**低于 1 万目标** |
| `EXTRA_ENV` | — | 透传给服务端容器的额外 `-e K=V` |

---

## 3. 判定标准

一个档位要**同时**满足四条才算「支撑得住」：

| 判据 | 含义 |
|---|---|
| `established ≥ 99%` | 连得上 |
| `droppedDuringHold ≈ 0` | 稳得住 |
| `deliveryRatio ≥ 0.99` | **送得到** —— 最容易被忽略的一条 |
| `p99 < 1000 ms` | 送得快（对齐参考服务 NFR-005） |

**第三条是唯一能区分「持有连接」和「服务连接」的判据。** 一台机器可以持有五万条连接却只给一半推帧，
只数连接数的压测会把这叫成功。

---

## 4. 在真机上跑之前必须改的

本批数据跑在单机 OrbStack 容器里。移到真机时：

1. **压测端与服务端分机部署** —— 本地同机时两者抢 CPU，已有三个档位因压测端饱和作废
2. **确认 `ulimit -n` 与 `ip_local_port_range`** —— 压测端每 (源IP, 目标IP:端口) 约 28K 端口，
   超过就要多容器/多 IP
3. **`HOLD` 拉长到 5–10 分钟** —— 90 秒足以暴露延迟，但不足以暴露内存泄漏与 GC 长期行为
4. **每档重复 3 次** —— 临界点附近方差极大（同配置实测出现过 p99 655 ms 与 2097 ms 之差）
