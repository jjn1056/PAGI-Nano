# Protocol, URL, and Service Correctness Design

**Date:** 2026-07-15

**Status:** Approved

## Goal

Fix three correctness defects found in PAGI-Nano and the related default
WebSocket-decline defect in PAGI-Tools:

1. Emit protocol-valid unmatched-route responses for HTTP, SSE, and WebSocket
   scopes.
2. Generate named-route URLs from decoded Perl strings using UTF-8-aware,
   route-semantic escaping.
3. Memoize every per-request service result, including `undef`.

The work spans `PAGI-Nano` and the sibling `PAGI-Tools` repository. The PAGI
protocol specification and PAGI-Server already define and implement the needed
WebSocket denial-response extension, so neither repository needs a behavior
change.

## Protocol Basis

`PAGI::Spec::Extensions` lists `websocket.http.response` as an official PAGI
extension. `PAGI::Spec::Www` defines both branches of WebSocket handshake
denial:

- When the server advertises
  `scope->{extensions}{'websocket.http.response'}`, the application may send
  `websocket.http.response.start` and `websocket.http.response.body`.
- When the extension is absent, the application sends `websocket.close` before
  acceptance and the server rejects the handshake with a bare HTTP 403.

SSE decline is a core capability and always uses
`sse.http.response.start`/`sse.http.response.body`. HTTP continues to use
`http.response.start`/`http.response.body`.

PAGI-Server already advertises and handles `websocket.http.response` for
HTTP/1.1 and HTTP/2. The implementation must consume the existing capability;
it must not define a new extension or require all PAGI servers to implement the
optional one.

## Protocol-Aware Unmatched Routes

### PAGI-Tools default behavior

`PAGI::App::Router` will make its default unmatched-WebSocket branch
extension-aware:

- Extension present: retain the custom namespaced 404 denial response.
- Extension absent: send `websocket.close`, allowing the server to produce the
  required bare 403.

Default HTTP and SSE behavior remains unchanged. The existing router
scope-decline test will cover both WebSocket capability states.

### PAGI-Nano custom `not_found`

Nano's custom `not_found` wrapper will dispatch by scope type:

- HTTP: invoke the custom handler through the existing HTTP response path.
- SSE: invoke the handler and translate its `http.response.*` output into
  `sse.http.response.*`.
- WebSocket with the extension: invoke the handler and translate its output
  into `websocket.http.response.*`.
- WebSocket without the extension: do not invoke a custom handler whose HTTP
  response cannot be represented; send `websocket.close` instead.

The translated WebSocket response may contain buffered or streamed `body`
events. It must reject `file` and `fh` body variants because the PAGI
WebSocket denial-response extension explicitly permits only the `body` form.
SSE translation follows the SSE decline event definition.

This behavior will be documented as capability-dependent. A custom WebSocket
404 body is available only when the server advertises the official extension;
the portable fallback is a body-less 403 handshake rejection.

## Spec-Aligned Named-Route URLs

`uri_for` accepts decoded Perl strings. It owns URL encoding; callers must not
pre-encode path or query values.

Escaping will operate on UTF-8 bytes using Perl core `Encode`. No new CPAN
dependency is required.

Path rendering distinguishes route token types:

- Literal route text is encoded as URL path text while preserving path
  separators.
- `:name`, `{name}`, and `{name:regex}` are single-segment placeholders. Their
  values are UTF-8 percent-encoded, and a value containing `/` croaks with an
  error that directs the caller to use a splat route.
- `*name` is a path-valued placeholder. Its `/` separators are preserved while
  each segment is UTF-8 percent-encoded independently.

Rejecting `/` in an ordinary placeholder is required for PAGI route
reversibility. PAGI percent-decodes `raw_path` before setting decoded
`scope->{path}`; therefore encoding `/` as `%2F` would still present `/` to the
router and split the value into multiple segments.

Query keys and values remain scalar and deterministically key-sorted. Spaces
continue to use `%20` for compatibility with the current output. Unicode and
reserved characters are encoded from UTF-8 bytes. Literal `%`, `?`, and `#` in
parameter values are encoded rather than treated as pre-encoded input or URL
delimiters.

Array-valued query parameters, missing-placeholder validation, and validation
against `{name:regex}` constraints are outside this change.

## Complete Per-Request Service Memoization

The service registry's per-request cache will use an `exists` check rather than
`//=`:

1. Return the cached value when the service name exists in the scope cache.
2. Otherwise invoke the per-request maker once, store its result verbatim, and
   return it.

This preserves the documented first-access semantics for every Perl value,
including `undef`, `0`, the empty string, references, and coderefs. App-scoped
services and per-call factories are unchanged.

## Files and Responsibilities

### PAGI-Tools

- `lib/PAGI/App/Router.pm` — extension-aware default WebSocket decline.
- `t/app-router-scope-decline.t` — default decline behavior for HTTP, SSE, and
  both WebSocket extension states.

### PAGI-Nano

- `lib/PAGI/Nano.pm` — protocol-aware custom `not_found` wrapping and POD.
- `lib/PAGI/Nano/Context.pm` — UTF-8 URL rendering and escaping.
- `lib/PAGI/Nano/ServiceRegistry.pm` — exists-based per-request memoization.
- `t/11-not-found-protocols.t` — focused custom `not_found` protocol tests.
- `t/09-named-routes.t` — URL escaping and placeholder-semantics tests.
- `t/service.t` — false/undefined per-request service memoization tests.
- `Changes` — user-visible compatibility and correctness notes.

No production files in `PAGI` or `PAGI-Server` change.

## Compatibility

Two formerly silent invalid cases become loud or capability-dependent:

- `uri_for` croaks when an ordinary placeholder value contains `/`; callers
  that intentionally carry a path use a `*splat` route.
- On a WebSocket scope without `websocket.http.response`, Nano cannot send a
  custom response body and falls back to the spec-defined bare 403 rejection.

Valid ASCII URLs, HTTP custom 404s, SSE custom 404s, WebSocket custom 404s on
supporting servers, app-scoped services, per-call factories, and defined
per-request service values retain their public behavior.

## Testing and Verification

Development follows red-green-refactor for each independent defect:

1. Add failing PAGI-Tools tests for unmatched WebSockets with and without the
   extension; implement the router fix; run the focused and full Tools suites.
2. Add failing Nano protocol tests for HTTP, SSE, supported WebSocket, fallback
   WebSocket, streaming bodies, and forbidden WebSocket file bodies; implement
   the scope-aware wrapper; run the focused Nano tests.
3. Add failing named-route tests for Unicode, reserved characters,
   ordinary-placeholder slash rejection, splat preservation, and query
   encoding; implement byte-aware URL rendering; run `t/09-named-routes.t`.
4. Add a failing test proving an `undef` per-request maker runs once; implement
   exists-based caching; run `t/service.t`.
5. Run the complete PAGI-Tools and PAGI-Nano test suites in the documented Perl
   5.40 development environment.
6. Run POD validation for modified modules and `git diff --check` in both
   repositories.

PAGI and PAGI-Server serve as specification and implementation references. No
new server feature or protocol conformance test is required because the denial
extension and its fallback are already covered there.
