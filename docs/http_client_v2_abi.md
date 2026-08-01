# HTTP Client v2 ABI Contract

## Status and Polling

v2 status values are fixed as `ok=0`, `would_block=1`, `closed=2`, `timeout=3`, `too_large=4`, `invalid=5`, and `io_error=6`. They are independent of the plugin descriptor `AbiStatus` values used by v1.

WebSocket poll interests and returned event bits are:

- `readable = 1`
- `writable = 2`
- `closed = 4`

`sa_http_websocket_poll_v2(..., timeout_ms=0, ...)` returns `would_block` if no requested event is ready. A positive timeout returns `timeout` when it expires. Output slots are cleared before validation or I/O.

## HTTP Requests

Create a retained v2 request with `sa_http_client_req_new_v2`. Methods retain the v1 discriminants: GET `1`, POST `2`, PUT `3`, and DELETE `4`.

`sa_http_client_req_set_timeout_v2` sets the request deadline in milliseconds. Zero disables the request deadline. `sa_http_client_req_set_max_response_bytes_v2` must be nonzero and defaults to 16 MiB.

`sa_http_client_req_send_async_v2` clones and owns the request data. The caller may then free the source request and client. Poll returns `ready=1` for every terminal state, including timeout, cancellation (`closed`), size failure, and I/O failure. A response can be taken once.

Cancellation shuts down an already-published socket to wake blocked send/read operations. Zig 0.14.1 exposes the socket only after DNS, TCP connect, and TLS initialization complete. Those setup phases cannot be interrupted by this ABI; cancellation is observed immediately afterward, and `async_free_v2` may wait for the operating system's connect resolution. No redirected request is followed, which keeps cancellation tied to one file descriptor.

## WebSockets

Use one of these connection forms:

- `sa_http_client_websocket_connect_v2`: `ws://` TCP or `wss://` TLS.
- `sa_http_client_websocket_connect_unix_v2`: Unix socket path plus a logical `ws://host/path?query` URL.
- `sa_http_client_req_websocket_connect_v2`: the same TCP/TLS transport with headers from a request handle.
- `sa_http_client_req_websocket_connect_unix_v2`: Unix transport with headers from a request handle.

Unix mode rejects `wss://`; the socket is the physical transport and the logical URL supplies HTTP request semantics. TLS mode keeps the original `std.http.Client.Connection`, including its TLS state and post-upgrade buffered bytes. It never duplicates a raw TLS file descriptor.

`sa_http_websocket_read_v2` is nonblocking after polling. It returns text opcode `1` or binary opcode `2`, reassembles continuation frames, handles ping/pong internally, and returns `closed` for a valid peer close. Invalid or oversized framing closes the transport to avoid stream desynchronization.

The returned message pointer is borrowed from the WebSocket handle. It remains valid until the next successful read or `sa_http_websocket_free_v2`. The caller must not free it.

`sa_http_websocket_write_v2` writes one complete, masked client message. On `ok`, `out_written` equals the payload length; on every other status it is zero. Text must be UTF-8. Ping and pong payloads are limited to 125 bytes. All messages are limited to 16 MiB.

`sa_http_websocket_close_v2` accepts valid RFC 6455 close codes and a UTF-8 reason up to 123 bytes. `sa_http_websocket_free_v2` closes the transport and releases its retained client reference.

## Ownership

- A v2 request retains its client until request free.
- A v2 async operation retains its cloned request and client until async free.
- A v2 WebSocket retains its client and connection until WebSocket free.
- The owner may call `sa_http_client_free` after creating these handles.
- Response body/header pointers remain owned by the response and are invalid after response free.
- Concurrent free with another call on the same handle is invalid. WebSocket poll/read/write/close calls are serialized internally.

## Known Limits

- DNS, blocking connect, and the initial TLS handshake are not hard-interruptible with Zig 0.14.1 `std.http.Client`.
- TLS reads and writes are bounded after poll, but a partially timed-out TLS record makes the connection unusable and it is closed rather than replayed.
- v2 does not automatically follow redirects, retry requests, or implement HTTP/2 or HTTP/3.
- The legacy WebSocket ABI is preserved for compatibility and retains its blocking semantics; it should not be used for new work.
