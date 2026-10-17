# sa_plugin_http_client 0.17 测试状态

验证时间: 2026-10-17, zig 0.17.0, sci main, LLVM-20
命令: `zig build test --summary all --test-timeout 30s`

## 结果: 11 通过 / 4 失败 / 2 超时 (共17)

### 通过 (11)
- abi maps missing get URL to cli diagnostic
- exports runtime descriptor and loopback GET works
- saasm api exposes response headers
- builds joined upstream URL and OpenAI auth headers
- async request poll and take response
- custom CA bundle path is accepted by parser
- post command forwards headers and body
- v2 status values and invalid arguments are stable
- v2 enforces request deadline and response limit
- v2 leaves redirects to the caller
- (另1个通过, 含main模块测试)

### 失败 (4)
1. **SSE stream**: 期望body无`status: 200`前缀, 实际`runHttpStreamRequest`
   直接复用`runHttpRequest`会打印`status: 200\n`头 — 需改stream实现
   去掉status行, 只输出body (tests/plugin_test.zig:479)
2. **TLS CA bundle (openssl s_server)**: ConnectionRefused —
   测试桩`openssl s_server -www`与客户端握手时序问题, 需排查
   (tests/plugin_test.zig:659)
3. **Unix ws read**: 期望ok(0)实际closed(2) —
   `websocketServerHandshake`后服务端写帧时序/读端关闭问题
   (tests/plugin_test.zig:1016)
4. **Oversized ws read**: 期望too_large(4)实际closed(2) —
   同上, 服务端发超大帧后客户端直接closed (tests/plugin_test.zig:1053)

### 超时30s (2)
5. **TCP ws fragments/pongs/masks/closes**: 挂起 —
   客户端读循环与服务端ping/pong时序死锁?
6. **TLS ws**: 挂起 — 同2, openssl s_server基础设施问题?

## 已修 (本轮)
- tests/plugin_test.zig: std.net->std.Io.net, listen/accept/deinit/close
  加sio.io(), socket.address.getPort(), std.fs.cwd->sio.cwd,
  Child->sio.Child, tmp Dir包装, sleepNs, raw-socket HTTP stub
  (TcpConn+readRawRequest+headerValue/requestTarget) 替代已删除的
  std.http.Server.init(conn, buf), runWithCapture替代writer().any(),
  Stream.writer接口flush, TcpConn.read用posix绕过std Stream.read解构bug
- src/http_v2_api.zig + http_saasm_api.zig: Uri.path联合体
  (.raw/.percent_encoded)崩溃修复
