# 四插件依赖关系重构计划（草案）

> **日期**：2026-06-15
> **状态**：Step 1 已落地（仅 `sap.json` 三处声明改动，零代码改动），Step 2+ 待用户审核后推进
> **目标**：把"应用门面依赖通用能力"这个本来就该有的抽象层次显式化到 `sap.json` 与 Zig 实现两层
> **关联评估**：[`plugin_evaluation_cn.md`](./plugin_evaluation_cn.md)（四插件综合评估）

---

## 1. 重构前后对比

### 1.1 重构前（错位）

```
http-server  → (无依赖)
http-client  → node                       ← 反向：通用能力依赖 JS 兼容门面
deno         → http-client, http-server
node         → (无依赖)
```

### 1.2 重构后（正确层级）

```
http-server                          ← 叶子：通用 HTTP/1.1 server，零插件依赖
http-client                          ← 叶子：通用 HTTP/1.1 + TLS client，零插件依赖
       ↑           ↑
       │           │
       └────┬──────┘
            │
   ┌────────┴────────┐
   │                 │
  node              deno
   │                 │
  node.http /        Deno.serve /
  node.https /       fetch /
  node.net           Deno.connect 等
  复用 http-*        复用 http-*
```

### 1.3 抽象层级原则

```
应用语义层    deno / node                  （JS 生态兼容门面）
                ↑ 依赖
功能能力层    http-client / http-server     （通用网络能力）
                ↑ 依赖
原语层        Zig std / sa_std              （底层）
```

**正确依赖方向**：上层调用下层。
- node 实现 `node.http` / `node.https` / `node.net` —— **应用层 API**，应该**复用** http-server / http-client 这些**功能层插件**
- deno 实现 `Deno.serve()` / `fetch()` —— 同理

---

## 2. 改动收益

| 收益 | 说明 |
|------|------|
| **使命清晰** | http-* 是通用能力，node/deno 是 JS 兼容门面；语义对齐物理依赖 |
| **node 大幅瘦身** | `node.http` / `node.https` / `node.net` 走 http-* 的 ABI，**估计能砍掉数千行 Zig** |
| **避免重复实现** | 当前 node 自己实现 TCP/HTTP（grep 显示有 `connect/getaddrinfo`），http-* 又有一套，两套维护、两套 bug |
| **测试矩阵收敛** | http-* 通过测试 → node 网络相关测试自动受益 |
| **轻量用户路径** | 想用 HTTP 但不用 Node/Deno 的用户，只装 http-*，安装体积 / 启动延迟小 10× |
| **解锁循环依赖隐患** | 当前 node 自己有 `node.http` skill 又被 http-client 依赖，循环未发生只是因为现在没真正复用 |

---

## 3. Step 1：sap.json 声明改动（已完成）

### 3.1 已落地的三处改动

**A. `sa_plugin_http_client/sap.json`** —— 删除反向依赖

```diff
- "dependencies": {
-   "node": {
-     "version": ">=0.1.0",
-     "abi": 1,
-     "path": "../sa_plugin_node"
-   }
- }
+ "dependencies": {}
```

**B. `sa_plugin_node/sap.json`** —— 添加正向依赖

```diff
- "dependencies": {}
+ "dependencies": {
+   "http-client": {
+     "version": ">=0.1.0",
+     "abi": 1,
+     "path": "../sa_plugin_http_client"
+   },
+   "http-server": {
+     "version": ">=0.1.0",
+     "abi": 1,
+     "path": "../sa_plugin_http_server"
+   }
+ }
```

**C. `sa_plugin_deno/sap.json`** —— 无改动（依赖关系本来就对）

```
deno → http-client, http-server  ✓
```

### 3.2 Step 1 性质

- **零 Zig 代码改动**
- **零 ABI 变更**
- **零行为变化**：node 暂时仍走自己内部的 TCP/HTTP 实现；http-client 不再"假装"被 node 依赖
- **仅声明层面对齐**：之后做 Step 2 切换实现时，依赖图已就位

### 3.3 Step 1 验证清单

| 验证项 | 命令 | 期望 |
|--------|------|------|
| 三处 JSON 合法 | `jq . sap.json` | 各自正常输出 |
| dev install 不报错 | `SA_PLUGIN_DEV=1 sa plugin install --dev <path>` | 四个插件都能装 |
| 已有测试不回归 | `zig build test`（每插件） | 全过 |
| 依赖图 DAG 无环 | 用户审核 | http-* → node/deno 单向 |

---

## 4. Step 2：node 内部 HTTP/TCP 实现切换到 http-*

> **状态**：未启动；等用户审核 Step 1 后决策

### 4.1 切换范围（仅以下模块）

| Node 模块 | 当前 Zig 实现位置（推测） | 目标 |
|----------|-----------------------|------|
| `node.http` | `src/node_saasm_api.zig` 中 http 相关导出 + `src/node_http_bridge.zig`（295 行） | 走 `sa_http_server_*` / `sa_http_client_*` |
| `node.https` | 同上 + TLS | 走 `sa_http_client_new(use_tls=1, ...)` |
| `node.net` | `src/node_saasm_api.zig` 中 `sa_node_plugin_net_*`（grep 显示 `connect/getaddrinfo`） | 通用 TCP 可暂保留；HTTP 路径切走 |
| `node.dgram` | UDP 部分 | **不切换**（http-* 不做 UDP） |

### 4.2 不动的模块

| 类别 | 模块 |
|------|------|
| 文件系统 | `fs`, `path`, `os` |
| 加密 | `crypto`, `tls`（除非 TLS 走 http-client 通道） |
| 进程 | `child_process`, `cluster`, `worker_threads` |
| 工具 | `util`, `events`, `stream`, `buffer` |
| DNS | `dns`（独立于 http-*） |
| 其他 | 35+ 个非网络模块 |

### 4.3 实施分步

| 顺序 | 任务 | 工程量 |
|------|------|--------|
| 2.1 | 列出 `node_saasm_api.zig` 中所有自实现的 HTTP/TCP 函数（待 grep 清单） | 2 天 |
| 2.2 | 把 `node.http` 出方向调用切换到 `sa_http_client_*` | 1 周 |
| 2.3 | 把 `node.http` 入方向监听切换到 `sa_http_server_*` | 1 周 |
| 2.4 | 砍掉 `src/node_http_bridge.zig`（如不再需要） | 2 天 |
| 2.5 | node 全测试矩阵跑通（195 个 `.sa`） | 持续验证 |

**预计总工程量**：2-4 周（按 1 人计）

**预计代码删减**：node 仓库 1500-3000 行 Zig 可被 http-* 等价替代

### 4.4 关键风险与缓解

| 风险 | 缓解 |
|------|------|
| node 195 测试有依赖内部 TCP 状态的特定行为 | 切换前先跑一遍 baseline，确认每条切换都不破回归 |
| node 当前 `net` 白名单仅 `http://127.0.0.1:18395` | 切换后 IPC 端口语义变更，需重新审视 net 白名单 |
| `child_process` 白名单仅 echo —— 暗示该模块未真正完成 | 与本次重构无关；不动 |
| ABI 漂移 | node 对外 `.sai` / `.sal` 不能变；只换底层实现 |
| node 18395 端口的硬编码 | 切换 IPC 通道时一并配置化 |

---

## 5. Step 3：deno 网络路径审视

> **状态**：未启动；与 Step 2 可并行或顺序

### 5.1 审视范围

deno 内部哪些 API 触发了 http-client / http-server 依赖：
- `Deno.serve()` → 应走 `sa_http_server_*`
- `Deno.connect()` / `Deno.listen()` → 走 http-server 或独立 TCP API
- `fetch()` → 应走 `sa_http_client_*`
- `WebSocket` → 暂不支持（http-server 当前也无 WS）

### 5.2 deno 网络与 hubproxy 的关系

`src/hubproxy_compat.zig`（3953 行，占 deno 插件 77%）是独立问题：
- **本次重构不涉及**
- 见评估报告 §3.3 关于 hubproxy 归属的讨论
- 建议：先做依赖重构，再独立处理 hubproxy 剥离

---

## 6. 需要决策的两点

### 6.1 Step 2 是否同时砍掉 node 的内部 TCP 实现？

| 选项 | 优 | 劣 |
|------|----|----|
| 全砍 | 真正瘦身；代码债务清零 | 工程量大；测试风险高 |
| 保留过渡 | 风险低；分步验证 | 代码债务累积；两套维护 |

**推荐**：**先 Step 1（已完成），再分模块逐步砍**。不要 big-bang。
具体顺序建议：`node.http` 出方向 → `node.http` 入方向 → `node.https` → 评估 `node.net`。

### 6.2 deno 是否应该依赖 node？

- ❌ **不应该**。Deno 有意与 Node API 解耦（如 `Deno.readFile` vs `fs.readFile`）
- ✅ deno 和 node 都依赖 http-* —— 两者是**平级门面**

**结论**：当前 sap.json 已是这个关系（deno → http-client/http-server，无 node 依赖），无需调整。

---

## 7. 已注意的细节（不动它们）

| 细节 | 说明 |
|------|------|
| **跨进程 vs 同进程调用** | http-client/server 当前是同进程动态库，node 调用它们也是同进程 dlopen 同一个 `.so`，**无 IPC 开销**。这是 SA 插件模型的天然优势 |
| **ABI 版本锁** | 三处 sap.json 都已写明 `abi: 1`，避免后续 http-* 不兼容升级把 node 拖坏 |
| **node 内部 IPC 端口 18395** | 与本次重构正交，但 Step 2 时应一并审视是否还需要该端口 |
| **child_process 白名单仅 echo** | 暗示该模块未真正完成；与本次重构无关 |
| **deno hubproxy_compat 3953 行 MCP 代码** | 独立问题，建议另起 PR 剥离成 `sa_plugin_mcp_hub` |

---

## 8. 当前状态与等待的审核点

### 8.1 已落地

- ✅ `sa_plugin_http_client/sap.json` 删除反向 `node` 依赖
- ✅ `sa_plugin_node/sap.json` 添加正向 `http-client` + `http-server` 依赖
- ✅ `sa_plugin_deno/sap.json` 无需改动（依赖关系本来就对）
- ✅ 本规范文档落到四个插件 `docs/dependency_refactor_plan_cn.md`

### 8.2 等待用户审核

- 三处 sap.json 改动是否符合预期
- Step 2 何时启动（推荐用户自己分模块推进）
- 是否需要先做 `node_saasm_api.zig` 中 HTTP/TCP 代码的待迁移清单 grep

### 8.3 用户审核后可独立推进的事项

- Step 2.1: 待迁移代码 grep 清单（1-2 天）
- Step 2.2-2.4: node HTTP/TCP 切换实现（2-4 周，可分多个 PR）
- Step 3: deno 网络路径审视（1 周）
- hubproxy 剥离独立讨论

---

## 9. 一句话总结

**依赖关系翻转是正确的工程整理**——把"应用门面依赖通用能力"这个本来就该有的层次显式化。

**Step 1（sap.json 三处声明）已完成，零代码改动、零 ABI 变更、零行为变化**，只是把依赖图调到了正确方向。

**Step 2-3 的真实瘦身工作**（让 node 真正复用 http-* 实现）由用户审核后自行推进；本计划文档为后续重构提供完整参照。

---

## 附录 A：本次改动文件清单

| 文件 | 操作 | 行变更 |
|------|------|--------|
| `sa_plugins/sa_plugin_http_client/sap.json` | 删除 `dependencies.node` | -6 / +1 |
| `sa_plugins/sa_plugin_node/sap.json` | 添加 `dependencies.http-client` + `dependencies.http-server` | -1 / +12 |
| `sa_plugins/sa_plugin_deno/sap.json` | 无改动 | 0 |
| `sa_plugins/sa_plugin_http_server/sap.json` | 无改动 | 0 |
| `sa_plugins/sa_plugin_http_server/docs/dependency_refactor_plan_cn.md` | 新增 | +N |
| `sa_plugins/sa_plugin_http_client/docs/dependency_refactor_plan_cn.md` | 新增 | +N |
| `sa_plugins/sa_plugin_deno/docs/dependency_refactor_plan_cn.md` | 新增 | +N |
| `sa_plugins/sa_plugin_node/docs/dependency_refactor_plan_cn.md` | 新增 | +N |

四份计划文档内容相同，每个插件目录下独立保存一份。
