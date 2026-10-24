# SA HTTP Client Plugin

> **Build requirement: Zig 0.17** — this plugin targets and is verified against **Zig 0.17.0**. Build and test with Zig 0.17; older toolchains such as 0.14.x are not supported.
> 本插件需使用 **Zig 0.17** 编译与测试。


`http-client` provides native HTTP/1.1, HTTPS, streaming responses, and WebSocket transports to SA programs. The original ABI remains available. The v2 ABI adds stable network statuses, request limits and cancellation, and WebSocket support over TCP, TLS, and Unix-domain sockets.

## Development

This plugin is intended to be used from a local development checkout:

```sh
timeout 300s env SA_PLUGIN_DEV=1 zig build test
timeout 300s env SA_PLUGIN_DEV=1 zig build
timeout 120s env SA_PLUGIN_DEV=1 sa plugin install --dev .
timeout 30s env SA_PLUGIN_DEV=1 sa plugin list
```

The Zig build uses the sibling SCI checkout at `../../sci` by default. Override it with `-Dsci-root=/absolute/path/to/sci` when necessary.

## v2 Overview

Every v2 operation returns one of the following network statuses:

| Value | Name | Meaning |
| ---: | --- | --- |
| 0 | `ok` | Operation completed. |
| 1 | `would_block` | A zero-time poll or nonblocking operation is not ready. |
| 2 | `closed` | The peer closed, cancellation completed, or the transport is no longer usable. |
| 3 | `timeout` | A positive deadline expired. |
| 4 | `too_large` | A configured body or message limit was exceeded. |
| 5 | `invalid` | Arguments, URI, headers, handshake, or WebSocket framing are invalid. |
| 6 | `io_error` | The transport or allocator failed without a more specific status. |

Request v2 adds:

- validated request construction, headers, and bodies;
- a total request deadline after transport setup becomes observable;
- a caller-defined response-body limit;
- condition-based async polling, cancellation, and response transfer;
- retained client ownership for v2 request, async, and WebSocket handles;
- caller-visible `302` responses instead of hidden redirect following.

WebSocket v2 adds:

- `ws://` over TCP and `wss://` over TLS;
- `ws://` over a Unix socket while retaining a separate logical URL for Host, path, and query;
- readable/writable/closed poll event bits `1`, `2`, and `4`;
- fragmented-message reassembly, automatic pong, close validation, and client masking;
- a 16 MiB message ceiling and borrowed message storage owned by the WebSocket handle.

See [docs/http_client_v2_abi.md](docs/http_client_v2_abi.md) for the ABI contract and ownership rules.

## Compatibility

All pre-existing v1 symbols and return codes remain unchanged. The four legacy blocking WebSocket exports are now declared in `sa_http_client.sai` so existing native symbols are visible, but new code should use the `_v2` functions.

The product target is Linux x86_64. HTTP/2, HTTP/3, strict nonblocking TLS record resumption, automatic retries, and interruptible DNS are outside this foundation.

## 已知安装问题（2026-10-08 实测）

- **sci 检出路径**：`build.zig` 默认 `-Dsci-root=../../sci`（同级检出布局）。扁平单仓布局（如所有仓并列于同一目录）下该相对路径解析不到 sci，
  报错 `'/content/sci/src/runtime/sa_net_primitives.zig' file_hash FileNotFound` 类。解法（三选一）：按同级布局检出、
  建 symlink（如 `ln -s /content/sa_all/sci /content/sci`，零仓库改动）、或构建时传 `-Dsci-root=<sci 绝对路径>`
 （注：`sa plugin install` 不透传该选项，走安装器时只能用前两种）。
- **真 zig 必须在 `PATH` 首位**：环境若有 zig shim（如 node 版包装器），构建报 `TestOptions` 结构错。安装前执行
  `export PATH=<zig-0.14.1-dir>:$PATH`（本仓要求 Zig ≥ 0.14.1）。
- **特权确认**：含宽网权限的插件正式安装需 TTY 下输入确切插件名确认；本机开发验证可用 `sa plugin install --dev .`
 （配 `SA_PLUGIN_DEV=1` 测试），如 README Development 节所示。

## 0.2.0（2026-10-24）：内核已内置 sa_std

HTTP 客户端内核（全部 `sa_http_client_*` / `sa_http_websocket_*` 符号：同步、异步 v2、
WebSocket 客户端、SSE）已迁入 sci 的 `src/runtime/sa_http_client.zig`，随 `libsa_std.a`
发布，声明位于 sci 的 `sa_std/http_client.sai`。**不安装本插件即可使用全部客户端能力。**

本仓库自 0.2.0 起只保留框架层：`sa http-client get/post/stream` CLI 便利命令与插件描述符；
原 `src/http_saasm_api.zig`、`src/http_v2_api.zig`、`src/sa_std_net.zig` 已删除。

架构原则：全部基础核心一律内置 sa_std；插件只是封装接口使用习惯（API 熟悉度与人体工学），
不代表可以把内涵/能力下放到插件。插件永远不是能力门槛。
