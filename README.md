# SA HTTP Client Plugin

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
