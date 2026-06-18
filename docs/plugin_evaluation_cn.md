# 四插件评估：sa_plugin_http_server / http_client / deno / node

> **评估日期**：2026-06-15
> **评估范围**：四个 SA 插件的使命、完成度、对外兼容性、安全模型、改进建议
> **评估方式**：`sap.json` / `.sai` / `.sal` 表面 + Zig 源码规模 + `progress.md` / `API_COVERAGE.md` + 测试矩阵 + 上游 design.md §1.7.1（插件契约）
> **立场**：诚实评估，按"使命对齐 + 完成度证据"打分；不做模糊外交辞令

> **本评估文档同时存放**：
> - `sa_plugins/sa_plugin_http_server/docs/plugin_evaluation_cn.md`
> - `sa_plugins/sa_plugin_http_client/docs/plugin_evaluation_cn.md`
> - `sa_plugins/sa_plugin_deno/docs/plugin_evaluation_cn.md`
> - `sa_plugins/sa_plugin_node/docs/plugin_evaluation_cn.md`
>
> 四份文件内容相同，每个插件目录下独立保存一份，便于各插件维护者快速访问。本文档为合并版总览。

---

## 0. 横向总览

| 插件 | 版本 | Zig 源码 | `.sai` 表面 | 测试 | progress 自评 | 真实定位 |
|------|------|---------|------------|------|-------------|---------|
| **http-server** | 0.1.0 | 1,056 行 | 18 extern | 1 plugin_test.zig + 1 example | 无 progress.md | 最小可用 HTTP server |
| **http-client** | 0.1.0 | 1,221 行 | 18 extern | 1 plugin_test.zig + 1 example | 无 progress.md | 同步/异步 HTTP client（含 TLS） |
| **deno** | 0.1.0 | 5,123 行 | 57 extern (`.sai`) + 959 行 `.sal` | 无独立 tests/ | 仅 `API_COVERAGE.md` | Deno 兼容子集（native replacement，非嵌入） |
| **node** | 0.1.0 | 21,538 行 | 235 + 925 extern (2 sai) + 21,551 行 sal | 195 个 `.sa` 测试 | 43/43 模块"100%" | Node 兼容门面（非 V8 / 非 VM） |

**直觉对比**：

```
体量轴：    node (43K 行)  >>  deno (6K 行)  >  http-client (1.2K)  >  http-server (1K)
风险轴：    node           >>  deno           >  http-client/server (清晰)
独立性轴：  http-server (无依赖)  >  deno (依赖 http-client + server)  >  http-client (依赖 node)
```

---

## 1. `sa_plugin_http_server`

### 1.1 使命定位

提供 SA 程序内嵌的 HTTP/1.1 服务端，让 `.sa` 代码直接 accept 连接、读请求、发响应。`sap.json` skill = `http.server`。

### 1.2 ABI 表面（极简且形态正确）

18 个 extern，按"生命周期 + 阶段"组织：

| 类别 | 函数 | 数量 |
|------|------|-----|
| Server 生命周期 | `new` / `start` / `accept` / `free` | 4 |
| Request 读取 | `req_get_method` / `req_get_path` / `req_get_header` / `req_get_body` / `req_free` | 5 |
| Response 一次性 | `resp_new` / `resp_set_content_type` / `resp_send` / `resp_free` | 4 |
| Response 流式 | `resp_stream_new` / `_write` / `_flush` / `_end` / `_free` | 5 |

**亮点**：
- ✅ 使用不透明 handle (`ptr`) + 显式 `^server` / `^resp` 释放，**完全符合 design.md §1.7.1 插件 ABI 约束**
- ✅ Response 一次性 + 流式双形态，覆盖 SSE / chunked 场景
- ✅ 18 行 `.sai`，**最干净的 ABI 之一**——LLM 几秒读完

### 1.3 权限模型评估

```
fs:      只 metadata 读 $SA_PLUGINS_HOME（用于发现自身共享资源）
net:     仅监听 http://localhost / 127.0.0.1（所有方法）
env:     HOME / TMPDIR / SA_* 等基本环境
process: 完全禁止 spawn
```

**评估**：
- ✅ 监听仅 localhost / 127.0.0.1：对内部 microservice、SAX dev server、localhost-only IPC 是正确选择
- 🟡 **缺 IPv6 `[::1]`**：localhost 模式下也应允许 `[::1]`，否则 IPv6-first 环境失败
- 🟠 **无 `https://` 监听能力**：当前 server 没有 TLS。但 sap.json 声明只允许 `http://localhost`，所以不会假装能做 TLS，**这是诚实的**
- ❌ **缺生产部署能力**：不能监听 0.0.0.0、不能监听其他端口范围，所以无法直接做生产 HTTP 服务。这与"本地 dev server / 内部 IPC" 定位一致，但**没有文档说清楚这个边界**

### 1.4 实现规模与缺口

1056 行 Zig 实现 18 个 extern 的完整 HTTP/1.1 server——**可信**（参考：Zig std HTTP server 也是这个量级）。

**未见**：
- HTTPS / TLS（明确不支持，OK）
- HTTP/2 / HTTP/3
- WebSocket
- 反向代理 / mTLS
- 大文件流式上传 multipart
- 连接超时 / keep-alive 调优 API
- access log / metric hook

**测试**：1 个 `plugin_test.zig` + 1 个 `examples/scaffold.sa`。**端到端 SA 程序测试缺失**。

### 1.5 完成度评分

| 维度 | 评分 | 说明 |
|------|------|------|
| ABI 设计 | ✅ 95% | 极简、handle 模型、流式 + 一次性双形态、ownership 前缀正确 |
| HTTP/1.1 子集 | ✅ 80% | 基本 GET/POST/Header/Body/Stream 全有 |
| TLS / HTTPS | ❌ 0% | 设计不做，靠 reverse proxy |
| WebSocket | ❌ 0% | 未做 |
| 生产监听（0.0.0.0 / 自定义端口） | ❌ 0% | 仅 localhost |
| 测试覆盖 | 🟠 30% | 缺端到端 SA smoke + 并发 / 大 body 测试 |
| 文档 | 🔴 10% | 无 README、无 progress.md，只有 18 行 sai |
| 安全模型 | ✅ 100% | localhost-only + 零 spawn + 零 env 越权 |

**整体：约 60-65%**。"localhost dev / 内部 IPC HTTP server"使命达成；**不是**生产级 HTTP server。

### 1.6 改进建议（按优先级）

1. ⭐⭐⭐⭐⭐ **加 README + 使命边界声明**："这是 localhost dev / SAX 配套 HTTP server，不替代生产 HTTP 服务器（用 nginx/caddy 反代）"
2. ⭐⭐⭐⭐ **加端到端 SA smoke**：用 http_client 反向调用，验证 GET / POST / chunked / 大 body / 并发 16 连接
3. ⭐⭐⭐ **加 IPv6 `[::1]` 监听** + sap.json 同步加白名单
4. ⭐⭐⭐ **WebSocket 评估**：SAX 实时更新场景刚需；若做，复用现有 stream API + 加 4 个 extern 即可
5. ⭐⭐ **handler 路由 / 中间件抽象**：不在 native 做，建议在 sa_std 加一层 `.sal` 宏 facade
6. ⭐⭐ **HTTP/2** 仅在 SAX 配套场景需要 server push 时考虑；否则不值得做
7. ❌ **不做 TLS**：定位明示靠反代

---

## 2. `sa_plugin_http_client`

### 2.1 使命定位

SA 程序内嵌的 HTTP/1.1 + TLS 客户端，提供同步 + 异步两套调用模型。skill = `http.client`。

### 2.2 ABI 表面

18 个 extern，结构对称 http-server：

| 类别 | 函数 |
|------|------|
| Client 生命周期 | `new(use_tls)` / `free` |
| Request 构造 | `req_new` / `req_add_header` / `req_set_body` / `req_free` |
| 同步发送 | `req_send` |
| 异步发送 | `req_send_async` / `async_poll` / `async_take_response` / `async_free` |
| Response 读 | `resp_status` / `resp_get_header` / `resp_body_slice` / `resp_body_reader` / `resp_read_chunk` / `resp_free` |
| Stream reader | `body_reader_free` |

**亮点**：
- ✅ **`use_tls: u8` 显式声明**——一个开关，TLS 透明启用，避免两套 client
- ✅ **同步 + 异步双轨**：异步走 `poll/take` handle，符合 design.md §1.7.1 "用 handle + `poll/take/free` 规范，而不是模拟 JS Promise"
- ✅ Body 既支持一次性 `body_slice`（小响应），也支持 `body_reader` + `read_chunk`（大响应 / 流式）

### 2.3 权限模型评估

```
fs:      读 $PROJECT/** + 读 /etc/**（证书路径）+ metadata $SA_PLUGINS_HOME
net:     https://* (所有方法) + http://localhost / 127.0.0.1
env:     SSL_CERT_FILE / SSL_CERT_DIR / *_PROXY / HOME / SA_*
process: 禁止 spawn
```

**评估**：
- ✅ **网络白名单是合理的中间路径**：https://* 全开（出 client 必备）+ http 仅 localhost（开发自连）+ 不允许 `http://*` 任意 plaintext 远程
- ✅ `/etc/**` 读权限明确说明用途（证书）
- ✅ Proxy 环境变量白名单完整（HTTP_PROXY / HTTPS_PROXY / NO_PROXY + 大小写两套）
- 🟡 **依赖 sa_plugin_node**：sap.json 写明 `dependencies.node`。但 http-client 不应依赖 node——会产生循环依赖风险（node 自己有 `node.http` skill，反过来要不要依赖 client？）
- 🟡 **缺 mTLS 客户端证书** API

### 2.4 实现规模

1221 行 Zig 实现包含 TLS / 异步 / chunked 的完整 client——**可信**（Zig std http client 也是这个量级，TLS 走 std.crypto）。

### 2.5 完成度评分

| 维度 | 评分 |
|------|------|
| ABI 设计 | ✅ 95% |
| HTTP/1.1 + TLS | ✅ 80% |
| 异步 poll/take 模型 | ✅ 90%（设计正确，需要测试证明） |
| 流式 body reader | ✅ 80% |
| mTLS / proxy auth | 🟠 50% |
| HTTP/2 | ❌ 0% |
| 重试 / 超时 / 限速 | 🟠 30%（推断；sai 未暴露超时设置） |
| 测试覆盖 | 🟠 30% |
| 文档 | 🔴 10% |
| 依赖关系 | 🟠 70%（依赖 node 待澄清） |

**整体：约 65%**。比 http-server 略高，因为 TLS + 异步两个硬难点都做了。

### 2.6 改进建议

1. ⭐⭐⭐⭐⭐ **澄清 `dependencies.node` 的真实关系**：为什么 client 要依赖 node？如果是间接 DNS / IPv6 解析，应该直接 link Zig std 而非引入 node；如果是异步 epoll，同理
2. ⭐⭐⭐⭐⭐ **加 README + 文档** 同 http-server
3. ⭐⭐⭐⭐ **加超时 / 重试 API**：`req_set_timeout_ms` / `req_set_max_redirects` / `req_set_retry_policy`（这些是 production-grade 必需）
4. ⭐⭐⭐⭐ **端到端测试矩阵**：vs `httpbin.org` 类样板服务的 30+ 用例（method / status / chunked / TLS / proxy / cancel）
5. ⭐⭐⭐ **mTLS 客户端证书**：加 `client_set_cert(client, &cert_pem, &key_pem)`
6. ⭐⭐ **HTTP/2**：低优先级，但对调用 gRPC / 现代 API 有用
7. ⭐⭐ **取消 API**：`async_cancel(op)`，用户 ctrl-c / 超时时清理

---

## 3. `sa_plugin_deno`

### 3.1 使命定位（自述）

> 来自 `API_COVERAGE.md`：
> "This plugin is a **native SA replacement surface** for Deno-compatible APIs. **It does not call the `deno` executable or embed the Deno runtime**."

这是关键信号：**deno 插件不是 deno runtime 嵌入，而是 deno API 表面的 SA 原生重实现**。符合 design.md §1.7.1 "插件不得静默调用被替代的外部运行时"。

skill = `deno.sys` / `deno.env` / `deno.fs` / `deno.process`。

### 3.2 ABI 表面

| 文件 | 行数 | extern 数 |
|------|------|----------|
| `deno.sai` | 68 | 57 |
| `deno.sal` | 959 | facade 宏 |

**已实现的子集**（来自 API_COVERAGE.md）：
- host/sys info, pid/ppid/uid/gid, memory usage
- env get/set/delete
- 文本文件 read/write
- random UUID
- args JSON
- base64 编解码
- text encode/decode 字节 helper
- version/build JSON
- wall-clock time
- mkdir / remove / copy / readDir / lstat
- command output

**显式标记 `planned_native`**（未实现）：
- cwd / chdir, chmod / chown, rename
- binary read / write, stat / realPath / readLink / symlink / truncate
- temp files / dirs, umask / kill
- DNS, permissions, file handles, network handles

**显式标记 `stub_unsupported`**（不会实现）：
- test / bench registration
- 完整 Web APIs
- WebGPU, KV, lint, Jupyter, browser-style event objects

### 3.3 内部代码组成（值得警惕）

5,123 行 Zig，**其中 3,953 行在 `hubproxy_compat.zig`**——这是什么？

grep 结果显示这里有 MCP (JSON-RPC) `initialize` 协议字符串。怀疑这是一个 **MCP hub proxy 兼容层**，与 deno API 表面无直接关系。

**如果属实**：
- 🔴 **使命漂移**：插件名叫 deno，但 77% 的代码在做 MCP hub proxy
- 🔴 **打包不当**：MCP proxy 应该独立成 `sa_plugin_mcp_hub`
- 🟡 **或**：hubproxy 是 deno 兼容子集的内部依赖（比如 deno permissions / fetch 走 hubproxy），那需要在 API_COVERAGE.md 里说清楚

### 3.4 权限模型评估

```
fs:      $PROJECT/** 全权（read/write/create/delete）
net:     https://* + http://localhost / 127.0.0.1
env:     HOME / PATH / SA_*
process: spawn 允许，exec 白名单 = /usr/bin/env *
```

**评估**：
- ✅ fs 限定 `$PROJECT/**`，比 deno 默认 `--allow-read` 更严
- ✅ net 与 http-client 类似——https 全开 + http 仅 localhost
- 🟠 **`exec /usr/bin/env *` 是逃生口**：通过 `env <随意命令>` 可绕过 exec 白名单的精确性。这是常见但**不严谨**的做法。应该实际声明被运行的命令路径
- 🟡 `dependencies.http-client` / `http-server` 声明明示——好的工程化实践
- 🟡 **依赖 http-server 是反直觉的**：deno 用户期望 client 不期望 server。怀疑是 Deno API 中 `Deno.serve(...)` 触发，但应该在文档明示

### 3.5 完成度评分

| 维度 | 评分 |
|------|------|
| ABI 设计（handle / poll/take） | ✅ 85% |
| 已实现 sys/env/fs/text 子集 | ✅ 70%（与 API_COVERAGE 的 `implemented` 列表一致） |
| `planned_native` 完整度 | 🟠 30%（cwd/binary IO/dns/permissions 缺） |
| Web APIs / WebGPU / KV | ❌ 0%（明确 stub） |
| 与 deno 真实兼容（端到端） | ❓ 未知，**无 deno 兼容性 smoke** |
| 使命对焦 | 🟠 60%（77% 代码在 hubproxy，不在 deno） |
| 权限模型 | 🟠 70%（`/usr/bin/env *` 是逃生口） |
| 文档 | ✅ 60%（有 API_COVERAGE，但缺 README + 设计文档） |

**整体：约 55-60%**。已实现的小子集质量在；但**使命焦点漂移 + 关键 IO 缺失**是真问题。

### 3.6 改进建议

1. ⭐⭐⭐⭐⭐ **澄清 hubproxy_compat.zig 的去留**：
   - **方案 A**：剥离成独立 `sa_plugin_mcp_hub`，让 deno 插件回到 ~1200 行专注 deno 表面
   - **方案 B**：保留并在 API_COVERAGE 明示"deno 插件同时实现 MCP hub proxy 兼容"，但这会让"deno 兼容"叙事混乱
2. ⭐⭐⭐⭐ **补全 `planned_native` 列表中的核心 IO**：cwd / chdir / binary read+write / stat / temp dir 是任何 deno 程序首日就会用到的
3. ⭐⭐⭐⭐ **加 deno 兼容性 smoke**：选 5-10 个真实 deno 脚本（不需要 Deno.serve / fetch）跑端到端
4. ⭐⭐⭐ **`exec` 白名单收紧**：把 `/usr/bin/env *` 替换为具体被调用程序的绝对路径
5. ⭐⭐⭐ **澄清依赖**：http-server / http-client 哪些 Deno API 触发；列入 API_COVERAGE
6. ⭐⭐ **DNS / permissions / Net handle**：deno 网络应用刚需，但工程量大

---

## 4. `sa_plugin_node`

### 4.1 使命定位（自述）

> 来自 `API_COVERAGE.md`：
> "This plugin is a **native SA compatibility layer for common Node.js APIs**. It does not execute JavaScript and does not depend on Node, V8, or VM APIs."

定位与 deno 一致：**native replacement surface，不嵌入 V8 / 不执行 JS**。

`progress.md` 自评 **43/43 模块完成 = 100%**。

### 4.2 体量

| 指标 | 数值 |
|------|------|
| Zig 源码 | **21,538 行**（全插件最大） |
| `node.sai` extern | 235 |
| `node_extra.sai` extern | **925** |
| 总 extern | **1,160** |
| `node.sal` + `node_extra.sal` | **21,551 行 SA facade** |
| 测试 .sa 文件 | **195 个** |

**这是整个 sa_plugins 仓库里规模最大的插件**——比 db 插件（33K）小，但 ABI 表面（1160 vs 285）几乎是 db 的 4 倍。

### 4.3 已实现 43 个模块（来自 progress.md）

```
async_hooks, assert, buffer, child_process, cluster, console, constants,
crypto, diagnostics_channel, dgram, dns, domain, events, fs, http, http2,
https, inspector, module, net, ...（共 43 个）
```

覆盖 Node.js 主要稳定 API 模块。

### 4.4 工程红旗（必须诚实指出）

**🔴 工程组织问题**：

`ls` 输出的根目录里有以下文件：
```
all_exported_symbols.txt
expand_calls.txt
expanded.sa
fix_sal.py
fix_test.py
macros_extra.txt
missing_macros.txt
node_macros.txt
reconstruct.py
recover_test.py
tests_macros.txt
tmp_test.o / tmp_test.sa / tmp_test.o.sa.bc
node.o / node.o.sa.bc / node_extra.o / node_extra.o.sa.bc
```

**问题**：这些是一次性脚本 / 中间产物 / 调试输出，**不应该进版本仓库**。这暗示：
- 开发期手忙脚乱，没建 `.gitignore` 卫生
- 有多个 Python 修复脚本（`fix_*.py`, `reconstruct.py`, `recover_test.py`）——说明 `.sai`/`.sal` 不是手写而是**生成的**，且生成过程中出过事故
- `node.o.sa.bc` 等编译产物入仓——膨胀仓库

**🔴 progress.md 100% 与 API_COVERAGE 的实际 surface 不匹配**：
- `progress.md` 列了 43 个模块，每个"completed"
- 但 `node.sai` (235) + `node_extra.sai` (925) = 1160 个 extern
- 每个模块平均 27 个 extern；这要么是高度细粒度（合理），要么是 facade 与真实实现不对称（红旗）
- **没有任何"端到端跑通真实 Node 脚本"的 smoke**——progress 报告的是"facade 写完了"，不是"Node 代码能跑了"

**🟡 net 监听端口 `18395` 硬编码到 sap.json**：

```json
"net": [
  { "url": "http://127.0.0.1:18395" },
  { "url": "http://localhost:18395" }
]
```

为什么是 18395？没文档说明。可能是 node-side IPC bridge 端口，但应该：
- 文档明示
- 允许配置（环境变量覆盖）
- 否则两个 node 插件实例同时运行会撞端口

**🟡 `exec` 白名单**：

```json
"exec": [
  { "path": "/bin/echo", "args": ["*"] },
  { "path": "/usr/bin/echo", "args": ["*"] }
]
```

只允许 echo？这看起来是 child_process 的占位测试白名单。**真实 Node child_process 需要 spawn 任意命令**，所以这要么是 child_process 不真实工作，要么是白名单严重欠缺。

### 4.5 完成度评分

| 维度 | 评分 |
|------|------|
| ABI 表面规模 | ✅ 100%（1160 extern，最大） |
| progress 列出的 43 模块 facade | ✅ 100%（按 progress 自述） |
| 真实 Node 脚本端到端兼容 | ❓ 未知 |
| 工程卫生（仓库整洁） | 🔴 30%（中间文件 / Python 修复脚本入库） |
| 测试覆盖（195 个 .sa 测试） | ✅ 80%（数量足够，质量需抽检） |
| child_process 真实可用 | 🟠 40%（exec 白名单仅 echo） |
| net IPC port 设计 | 🟠 50%（硬编码 18395） |
| 文档 | ✅ 70%（API_COVERAGE 在；缺 README/边界声明） |
| 使命对焦 | ✅ 90%（明确"non-V8 compat surface"） |

**整体：约 60-65%**。表面光鲜但工程内幕混乱。"43/43 100%" 是 facade 维度，不是"用户的 Node 代码跑通"维度。

### 4.6 改进建议

1. ⭐⭐⭐⭐⭐ **仓库卫生大扫除**：
   - 把根目录所有 `.txt` / `*.o` / `*.o.sa.bc` / `tmp_*` / `fix_*.py` / `reconstruct.py` / `recover_test.py` 加入 `.gitignore`
   - 已入库的删除（保留必要的 `.sai` / `.sal` / 真实测试 `.sa`）
   - 移到 `scripts/` 子目录，命名清晰
2. ⭐⭐⭐⭐⭐ **加端到端 Node 兼容性 smoke**：
   - 选 20-30 个真实 npm 包的最小用法（如 `crypto.createHash`, `fs.readFile`, `http.createServer`）
   - 用 SA 写出等价代码，与 Node.js 行为做差分
   - 这是"43/43 100%"的真正证据，不是 facade count
3. ⭐⭐⭐⭐ **child_process 白名单或子沙箱机制**：echo-only 显然不够。如果 child_process 设计上只是 echo placeholder，**API_COVERAGE 应明示**
4. ⭐⭐⭐⭐ **澄清 18395 端口**：文档明示用途、允许 env 覆盖、说明多实例冲突预期
5. ⭐⭐⭐ **拆分单一巨型 `node_saasm_api.zig`（4760 行）和 `node_extra.sal`（10777 行）**：按模块（fs/net/crypto/...）拆，便于维护
6. ⭐⭐⭐ **加 README**：明确"我是 Node 兼容门面，不是 Node runtime；以下子集已 verified，以下不支持"
7. ⭐⭐ **去掉 1160 个 extern 中的重复 / 死代码**：很可能 facade 自动生成时产生了大量未真正落地的桩

---

## 5. 横向对比与战略观察

### 5.1 ABI 表面规模 vs 真实可用度

| 插件 | extern 数 | 真实可用度（估计） |
|------|----------|-----------------|
| http-server | 18 | 高 |
| http-client | 18 | 高 |
| deno | 57 | 中 |
| node | 1,160 | **未知**（缺端到端证据） |

**模式**：随 ABI 表面膨胀，"真实可用度"反而降低。**18 个 extern 的 http-* 反而是最可信的**——因为容易测试、容易理解、容易审计。

### 5.2 权限模型清洁度排名

| 插件 | 评分 | 短评 |
|------|------|------|
| http-server | ✅ 最干净 | localhost-only + 零 spawn + 零越权 |
| http-client | ✅ 良好 | https://* 全开是必要 + proxy env 白名单完整 |
| deno | 🟠 中等 | `/usr/bin/env *` 是逃生口 |
| node | 🟠 中等 | exec 白名单形同虚设（仅 echo） |

### 5.3 依赖图

```
http-server  → (无)
http-client  → node (令人困惑)
deno         → http-client, http-server
node         → (无)
```

**潜在问题**：http-client 依赖 node 而 node 实现了 http skill（`node.http`）——**循环依赖风险**。

**建议**：http-client 应该直接 link Zig std，不依赖 node。

### 5.4 文档完整度排名

| 插件 | 评分 |
|------|------|
| deno | ✅ API_COVERAGE 完整 |
| node | ✅ API_COVERAGE + progress.md |
| http-server | 🔴 仅 sai 行内注释 |
| http-client | 🔴 仅 sai 行内注释 |

**反差**：实现质量高的两个反而文档最差。建议补 README + 使命边界声明。

### 5.5 测试覆盖度

| 插件 | 测试规模 | 质量评估 |
|------|---------|---------|
| node | 195 个 .sa | 数量充足，覆盖深度需抽检 |
| http-server | 1 unit + 1 example | 严重不足 |
| http-client | 1 unit + 1 example | 严重不足 |
| deno | 无独立 tests/ | 严重不足 |

**反差**：node 测试最多，但同时工程卫生最乱；http-* 测试最少，但 ABI 最干净。

### 5.6 一句话总结每个插件

| 插件 | 一句话 |
|------|--------|
| **http-server** | 18 行 sai 的极简 localhost HTTP server，是四个里最可信的一个，但缺文档让用户不敢用 |
| **http-client** | 18 行 sai + TLS + 异步双轨，设计水平最高，但与 node 的依赖关系令人困惑 |
| **deno** | 真使命是 Deno API 兼容子集，但 77% 代码在做 MCP hub proxy，存在使命漂移 |
| **node** | 体量最大、ABI 最广、自评 100%，但工程卫生最差、端到端兼容性证据最弱 |

---

## 6. 推荐改进顺序（跨四插件）

### 6.1 立即可做（不动 native）

| 优先级 | 任务 | 涉及插件 |
|--------|------|---------|
| ⭐⭐⭐⭐⭐ | **node 仓库卫生扫除** + `.gitignore` 完善 | node |
| ⭐⭐⭐⭐⭐ | 给四个插件加 README 边界声明 | 全部 |
| ⭐⭐⭐⭐ | 澄清 deno hubproxy_compat 的归属（剥离或文档化） | deno |
| ⭐⭐⭐⭐ | 澄清 http-client → node 依赖必要性 | http-client / node |
| ⭐⭐⭐ | 澄清 node 的 18395 端口 + child_process echo 白名单 | node |

### 6.2 1-2 个月内做

| 优先级 | 任务 | 涉及插件 |
|--------|------|---------|
| ⭐⭐⭐⭐⭐ | http-* 加端到端测试矩阵（30+ 用例） | http-server / http-client |
| ⭐⭐⭐⭐⭐ | deno 补全 planned_native 核心 IO（cwd/binary IO/stat/temp） | deno |
| ⭐⭐⭐⭐⭐ | node 加 20-30 个真实 npm 包 smoke 兼容性测试 | node |
| ⭐⭐⭐⭐ | http-client 加超时 / 重试 / 取消 API | http-client |
| ⭐⭐⭐ | deno hubproxy 剥离成独立插件（如保留方案 A） | deno + 新 mcp_hub |

### 6.3 长期

| 优先级 | 任务 |
|--------|------|
| ⭐⭐⭐ | http-server 加 WebSocket（SAX 实时刚需） |
| ⭐⭐ | http-client / server 加 mTLS |
| ⭐⭐ | node 巨型文件拆分（4760 / 10777 行单文件难维护） |
| ⭐⭐ | 全插件 sap.json 加 IPv6 `[::1]` 白名单 |
| ⭐ | HTTP/2 / HTTP/3 评估 |

### 6.4 不建议做（守住设计哲学）

| 想法 | 为什么不做 |
|------|-----------|
| http-server 加生产模式（监听 0.0.0.0） | 用 nginx/caddy 反代，零信任路径更稳 |
| deno 嵌入 V8 / 调用 deno 可执行 | 违背 design.md §1.7.1 |
| node 嵌入 V8 / VM | 同上 |
| 四个插件合并 | ABI 边界清晰是优势，不要破坏 |

---

## 7. 战略层面：四插件的角色重审

回顾你的目标（"SA 是 WASM 时代的安全运行时 + 平台叙事"）：

| 插件 | 主页对外承诺 | 真实状态 | 推荐 |
|------|------------|---------|------|
| http-server | "服务端栈" 旗舰 | 60-65% | ⭐⭐⭐⭐⭐ 旗舰候选——但需要 README + 测试 |
| http-client | "服务端栈" 一等公民 | 65% | ⭐⭐⭐⭐⭐ 同上 |
| deno | "TS/JS 多语言入口"之一 | 55-60% | ⭐⭐⭐ 不要作为入口主推，宣传为"experimental subset" |
| node | "TS/JS 多语言入口"之一 | 60-65%（表面） / **未知**（实际） | ⭐⭐⭐ 同上 |

**类比**：bc2sa 已经被你标 `experimental`。**deno / node 应该至少同等标注**——它们的真实可用度还低于 bc2sa（bc2sa 至少有清晰的 47 单元测试和静态越界拒绝亮点）。

**主页表格建议同步修改**：

```
| TypeScript | sa_plugin_ts (experimental) | ... |
| JS / Deno  | sa_plugin_deno (experimental) | Deno subset; not a Deno runtime |
| Node       | sa_plugin_node (experimental) | Node API surface; not Node runtime |
```

---

## 8. 一句话最终结论

**http-server / http-client 是真宝石**（ABI 干净、设计正确、安全模型严谨），缺的是文档 + 测试两件套，不是核心能力。

**deno / node 是表面光鲜内里复杂**——facade 写得多，端到端兼容性证据不足，工程卫生（特别是 node）有问题。需要诚实降级为 experimental，**并通过真实兼容性测试一步步证明可用度**。

**整个四件套的战略意义**：让 SA 在 WASM 边缘场景能"接入既有 Node / Deno / 浏览器生态"。但目前的承诺超过了真实能力。**先把 http-* 做成生产级，再把 deno / node 用真测试证明，比急着扩 API 表面更重要**。

---

## 附录 A：评估参考文件清单

| 插件 | 文件 | 行数 |
|------|------|------|
| http-server | `sap.json` / `sa_http_server.sai` / `src/*.zig` | — / 20 / 1056 |
| http-client | `sap.json` / `sa_http_client.sai` / `src/*.zig` | — / 20 / 1221 |
| deno | `sap.json` / `deno.sai` / `deno.sal` / `src/*.zig` / `API_COVERAGE.md` | — / 68 / 959 / 5123 / — |
| node | `sap.json` / `node.sai` / `node_extra.sai` / `*.sal` / `src/*.zig` / `progress.md` / `API_COVERAGE.md` | — / 287 / 926 / 21551 / 21538 / — / — |

## 附录 B：关键设计文档引用

- `sci/docs/design.md §1.7.1` 外部插件系统的真实契约
- `sci/docs/faq.md §架构与生态边界类` Plugin vs Package 区别
- `sci/readme.md` 多语言喂入与全栈插件矩阵
