# sa_plugin_http_client 0.17 测试状态

验证时间: 2026-10-17, zig 0.17.0, sci main, LLVM-20
命令: `zig build test --summary all --test-timeout 60s`

## 结果: 15 通过 / 1 失败 / 1 崩溃 (共17)

### 通过 (15)
- abi maps missing get URL to cli diagnostic
- exports runtime descriptor and loopback GET works
- saasm api exposes response headers
- builds joined upstream URL and OpenAI auth headers
- async request poll and take response
- custom CA bundle path is accepted by parser
- post command forwards headers and body
- SSE stream forwards chunked body (已修: 去掉 status: 前缀)
- v2 status values and invalid arguments are stable
- v2 enforces request deadline and response limit
- v2 leaves redirects to the caller
- v2 TCP websocket fragments/pongs/masks/closes (已修: posix rawRead + 握手 over-read 保留)
- v2 Unix websocket (已修: 同上)
- v2 oversized frame rejects with too_large (已修: 同上)
- (main 模块测试)

### 剩余 (2, 均为 TLS/openssl 相关)
1. **https ca bundle (`openssl s_server -www`)**: `error.TlsInitializationFailed`
   - 已排除 `-naccept 1` 竞态 (去掉后服务常驻, 首错保留)
   - 最小探针复现: CA 加载 OK, `std.http.Client.fetch` 报 TlsInitializationFailed,
     而 curl 对同一 s_server 正常 → 疑似 Zig 0.17 std TLS client 与
     openssl s_server 的兼容问题, 非本插件迁移引入 (待对标 sci 自身
     sa_tls_client 的 s_server 测试验证)
2. **v2 TLS websocket**: 同一 TLS 根因; 另有测试侧 `kill()` 后再 `wait()`
   触发 std assert 崩溃 (0.17 Child 语义变化), 需改测试只 kill 不 wait

## 已修 (本轮, 均已推送到 origin/0.17)
- tests/plugin_test.zig: std.net→std.Io.net 全量迁移, raw-socket HTTP stub
  替代已删除的 std.http.Server.init(conn, buf), runWithCapture,
  Stream.writer 接口 flush, TcpConn.read 用 posix 绕过 std Stream.read 解构 bug
- src/http_v2_api.zig + http_saasm_api.zig: Uri.path 联合体 (.raw/.percent_encoded) 崩溃
- src/plugin.zig: stream CLI 只输出 body (无 status: 行)
- src/http_v2_api.zig: WebSocketV2.rawRead 改 posix 直读 (Threaded backend
  下 Stream.Reader 不可用, 与 sci sa_ws_client 同因); 握手 over-read 字节
  存入 receive_buffer (修 unix/oversized/TCP ws closed)
- build.zig: 新增 -Dtest-filter 便于单测隔离
