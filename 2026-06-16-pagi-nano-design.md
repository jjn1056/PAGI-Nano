# PAGI::Nano — Design Spec

**Date:** 2026-06-16
**Status:** Design, pending review

## Overview

`PAGI::Nano` is a compact, elegant micro-framework front door over PAGI-Tools. It is for **demos/presentations** and for building **real but small apps** (roughly under 20 endpoints), with **zero dependencies** beyond what PAGI-Tools already requires and what ships with a modern Perl.

"Nano" means *compact*, not *few features*: routing, middleware, lifecycle, static files, streaming, WebSocket, SSE, and request shaping are all in scope. The win is that an entire small app fits on one screen and reads top-to-bottom.

### Guiding principles

1. **The DSL produces a value, not global state.** `app { ... }` runs a block-scoped collector (the same `local`-scoped technique `PAGI::Middleware::Builder`'s `builder { }` already uses) and *returns* an assembled PAGI app. This avoids the global-state flaw that forced Dancer's v1→v2 rewrite. The result is composable (mount it), nestable, testable, and many-per-process.
2. **No silo, no cliff.** The DSL is thin sugar over the exact PAGI objects you would use by hand — `PAGI::Context`, `PAGI::Response`, `PAGI::App::Router`, the builder, `PAGI::Lifespan`. You can drop to raw PAGI mid-app, and you graduate to structured PAGI with no rewrite (a Nano app already *is* a PAGI app).
3. **Anti-magic, with one deliberate exception.** The only "magic" is the return-value coercion, which is *local and predictable* (a return-value convention visible at the call site), not action-at-a-distance. `@INC` is never touched by the framework.
4. **Separation of concerns:** Nano *shapes* input (strong parameters) and *routes/responds*; **validation is out of scope** (use Valiant, a downstream dependency, outside Nano); **persistence is out of scope** (your code).

## The surface (reference example)

```perl
use v5.40;
use experimental 'signatures';
use PAGI::Nano;   # app · get post put patch del any · group mount · enable
                  # startup shutdown · static · not_found · websocket sse

my $app = app {
    startup async sub ($state) { $state->{tasks} = []; $state->{boot} = time };
    shutdown async sub ($state) { warn "up since $state->{boot}\n" };

    enable 'GZip';                     # app-wide middleware
    enable 'ErrorHandler';             # rich 5xx (uncaught errors are 500 by default anyway)
    static '/assets' => 'public/';     # GET /assets/* -> ./public

    get '/'       => sub ($c) { 'PAGI::Nano' };                  # String   -> text/plain
    any '/health' => ['AccessLog'] => sub ($c) { { ok => 1 } };  # route middleware; hash -> JSON

    group '/api' => ['RateLimit'] => sub {                       # prefix + shared middleware
        get  '/tasks'     => sub ($c)      { $c->state->{tasks} };           # arrayref -> JSON
        get  '/tasks/:id' => sub ($c, $id) {                                 # :id -> signature
            $c->state->{tasks}[$id - 1] // return $c->json({ error => 'not found' }, status => 404);
        };
        post '/tasks'     => sub ($c) {
            my $attrs = $c->params->required(
                'title', +{ tags => [] },
                sub ($c, $missing) { $c->json({ error => 'missing', fields => $missing }, status => 400) },
            );
            my $tasks = $c->state->{tasks};
            push @$tasks, { id => @$tasks + 1, %$attrs };
            $c->json($tasks->[-1], status => 201);
        };
    };

    # streaming request body -> streaming response, nothing buffered
    post '/upper' => sub ($c) {
        my $in = $c->req->body_stream;
        $c->response->stream(async sub ($w) {
            while (defined(my $chunk = await $in->next_chunk)) { await $w->write(uc $chunk) }
            await $w->close;
        });
    };

    sse '/events' => sub ($c) { my $s = $c->sse; await $s->send("tick $_") for 1 .. 5 };
    websocket '/echo' => sub ($c) {
        my $ws = $c->websocket;
        await $ws->each_json(async sub ($msg) { await $ws->send_json({ echo => $msg }) });
    };

    not_found sub ($c) { $c->json({ error => 'no such route' }, status => 404) };
};

$app;   # run: pagi-server app.pl
```

## Components (units and how they map to existing PAGI)

Nano is assembly + sugar; it introduces little new runtime.

| Unit | Responsibility | Built on |
|---|---|---|
| `lib/PAGI/Nano.pm` | The DSL: exports, the `app { }` block-scoped collector, the route/group/mount/enable/lifecycle/static/not_found verbs, the handler wrapper (Context construction, path-param passing, return-value coercion, error catch). | `PAGI::App::Router`, `PAGI::Middleware::Builder`, `PAGI::Lifespan`, `PAGI::App::File` |
| `lib/PAGI/Context/HTTP.pm` (modify) | Add `json` / `text` / `html` / `redirect` response sugar (delegating to `->response->…`, returning a `PAGI::Response` value). Shared with `Endpoint` handlers. | `PAGI::Response` |
| `lib/PAGI/Request/StructuredParameters.pm` (new) + `lib/PAGI/Request.pm` (modify) | Strong-parameters: `$req->structured_body/structured_query/structured_data` and the params object (`permitted`/`required`/`namespace`/`flatten_array_value`). A no-deps port of `Catalyst::TraitFor::Request::StructuredParameters`'s core, decoupled from Catalyst. `$c->params` is the Nano-facing DWIM alias. | core Perl only |

### `app { }` — the collector

`app (&)` localizes a current-collector (a fresh `PAGI::App::Router` plus a builder middleware list), runs the block (the verbs register into the localized collector), wraps the router in any `enable`'d middleware, wraps that in `PAGI::Lifespan` if `startup`/`shutdown` were declared, and returns the composed app value. No package globals; nesting is supported because the collector is dynamically scoped.

### Handler wrapper (the one piece of new dispatch logic)

For each HTTP route, Nano wraps the user's `sub ($c, @path_params)`:
1. Build the `PAGI::Context` for the scope.
2. Pull the route's declared `:placeholders` from `$scope->{path_params}` in path order and call `$handler->($c, @ordered_params)`.
3. Coerce the return value (see below) into a `PAGI::Response`.
4. Send it via `$c->respond($res)`.
5. Catch anything thrown: a respond-able (or coercible) value is sent as-is; anything else yields a 500.

WebSocket/SSE handlers are imperative (`$c->websocket` / `$c->sse`, return nothing) and are **not** coerced.

## Behavior detail

### Routing

- Verbs: `get post put patch del any`, where `del` avoids shadowing Perl's `delete` and `any` matches all methods. Each: `VERB '/path' => [optional \@middleware] => sub ($c, @path_params) { ... }`.
- `group '/prefix' => [optional \@middleware] => sub { ...nested verbs... }` — prefix + branch-shared middleware.
- `mount '/prefix' => $app_or_coercible` — nest any PAGI app (coerced via `to_app`).
- All map directly to `PAGI::App::Router` (`get/post/.../any/group/mount`, plus its HEAD→GET, 405-with-Allow, and OPTIONS-Allow behavior).

### Path placeholders → signature

A route's `:name` placeholders become the handler's parameters, in path order, after `$c`: `get '/u/:uid/p/:pid' => sub ($c, $uid, $pid) { … }`. The wrapper passes exactly the captured params, so a Perl signature mismatch is an immediate, clear error. `$c->req->path_param('name')` remains available. (Nano-only; `Endpoint` handlers keep using `$ctx->req->path_param`.)

### Middleware scopes

- `enable 'Name', %args` — app-wide.
- `[\@middleware]` before a route or `group` handler — route/branch scoped.
- Names (`'GZip'`), instances, and coderefs are all accepted and normalized the same way `enable` already normalizes them.
- These are **event-layer** middleware (`$scope,$receive,$send,$next`). Value-flow route middleware (B6) is an `Endpoint::Router` feature and is intentionally not part of Nano.

### Responses and coercion

A handler returns a value; Nano coerces it:

| Return | Becomes |
|---|---|
| a `PAGI::Response` | sent as-is |
| hashref / arrayref | `application/json` |
| defined non-ref scalar | `text/plain` |
| `return;` / `undef` | **loud error** ("handler returned no response") — catches the forgot-to-return bug |
| any other ref | error |

For explicit control: `$c->json($data, %opts)`, `$c->text($str, %opts)`, `$c->html($str, %opts)`, `$c->redirect($url, $status)` — sugar on the HTTP context returning `PAGI::Response` values (so `%opts` is `status`/`headers`/etc. via the existing factory options). JSON encoding enables `convert_blessed`, so any object with `TO_JSON` serializes itself.

### Lifecycle and shared state

- `startup async sub ($state) { … }` and `shutdown async sub ($state) { … }` — sugar over `PAGI::Lifespan`. `$state` is the shared, app-lifetime state hashref.
- Handlers read it via `$c->state` (already exists on Context).

### Static files, custom 404, errors

- `static '/url' => 'dir/'` — wraps `PAGI::App::File->new(root => 'dir/')` and mounts it at `/url`.
- `not_found sub ($c) { … }` — sets `PAGI::App::Router`'s `not_found` slot (the handler is wrapped + coerced like any other).
- Errors: uncaught exceptions → 500 by default; a thrown respond-able/coercible → sent; `enable 'ErrorHandler'` customizes rendering.

### Streaming, WebSocket, SSE

- Streaming out: `$c->response->stream(async sub ($w) { await $w->write($chunk); await $w->close })`.
- Streaming in: `$c->req->body_stream` then `await $in->next_chunk` (undef at end).
- `websocket '/path' => sub ($c) { my $ws = $c->websocket; … }` — `$ws->each_json`, `send_json`, `send_text`, `receive`, `accept`, `close`.
- `sse '/path' => sub ($c) { my $s = $c->sse; await $s->send($data) }`.

## Strong parameters (the StructuredParameters port)

A no-deps port of the *core* of `Catalyst::TraitFor::Request::StructuredParameters`, decoupled from Catalyst, living on `PAGI::Request` (general — `Endpoint` handlers get it too), surfaced through `$c`.

**Purpose:** whitelist and structure incoming params *before* they reach a model — a prior layer to validation, not validation itself. Validation is Valiant's job, downstream.

### API

- Source builders on the request (mirroring the original's explicit trio):
  - `$req->structured_body` — body/form params; flattens array values by default (HTML form quirk).
  - `$req->structured_query` — query string.
  - `$req->structured_data` — body data such as JSON; keeps arrays as-is.
  - `$c->params` — Nano-facing DWIM alias that selects body-vs-data by content-type.
- Params-object methods:
  - `permitted(@rules)` — lenient whitelist; returns a clean hashref of only the permitted, present keys.
  - `required(@rules, $on_missing)` — strict. The **trailing coderef is mandatory** (`required needs an on-missing callback` if omitted). On success returns the clean hashref; on any missing required key it invokes `$on_missing->($c, $missing)` and the response that returns is thrown and sent by Nano's dispatch. Passing `$c` (rather than closing over it) lets the callback be a shared named sub reused across routes.
  - `namespace(\@fields)` — scope all rules under a key (e.g. `['person']`).
  - `flatten_array_value($bool)` — toggle array-flattening.

### Rule syntax (from the original, kept verbatim)

```perl
->permitted(
    'username', 'password',             # scalar keys
    name => ['first', 'last'],          # nested hash      (from name.first / name.last)
    +{ email => [] },                   # array            (from email[0] / email[1])
    +{ children => [['name','age']] },  # array of hashes  (from children[0].name, children[1].age, …)
)
```

Flat form keys (`name.first`, `email[0]`) are reconstructed into nested structures; already-nested JSON is simply whitelisted. Validation/coercion of *values* is explicitly out of scope.

### Error model interaction (resolves the B2 question)

`required`'s mandatory on-missing callback makes the failure response *explicit and chosen at the call site*, so the throw is intentional plumbing, not a mystery die. This is the B2 "featherweight die-a-respond-able" escape hatch finally earning its keep — bounded, opt-in, never silent. Nano's dispatch is its consumer: thrown respond-able/coercible → sent; otherwise → 500.

## App layout and running

Nano never touches `@INC`. Lib-finding is standard Perl; the runner (`pagi-server`, a separate PAGI-Server dist concern) owns `-I`.

- **Quickstart / single file:** `app.pl` returning the app; `pagi-server app.pl`. When a `./lib` appears, add the core idiom:
  ```perl
  use FindBin; use lib "$FindBin::Bin/lib";
  ```
- **Real app (documented layout):** a modulino at `lib/MyApp.pm`:
  ```perl
  package MyApp;
  use PAGI::Nano;
  sub to_app ($class) { app { ... } }
  __PACKAGE__->to_app;   # last expression is the app, so loading the file returns it
  ```
  Run `pagi-server -Ilib lib/MyApp.pm` (one `-Ilib` puts the whole tree on `@INC`). Dual-use: `use MyApp; my $app = MyApp->to_app` for tests, or `mount '/x' => MyApp->to_app` to nest. This is the "grows up" path from `app.pl` — same app value, no rewrite.

Auto-adding the app's sibling `lib/` (as Dancer/Mojolicious do) is rejected for PAGI-Tools as implicit magic; if wanted, it belongs as an opt-in flag in PAGI-Server, not here.

## Non-goals (deliberate boundaries)

- **No templating engine** (no-deps) — HTML via strings / `$c->html`; bring your own templating or mount a templated sub-app.
- **No validation** — Valiant, downstream, outside Nano.
- **Not an ORM** — no SQL/relations/migrations; persistence is your code.
- **No value-flow route middleware** — that is `Endpoint::Router` (B6); Nano route middleware are event-layer.
- **Does not self-run** — returns an app; `pagi-server` runs it, or mount it in a larger app.

## Testing approach

- Because `app { }` returns a value, the primary test path is `PAGI::Test::Client` against the returned app — no server, no globals.
- Unit-level coverage for: the coercion table (each row, including the loud `return;` error); path-param→signature ordering; per-route/group/app middleware scoping; `static`/`not_found`/`startup`/`shutdown`; the error catch (respond-able thrown → sent, other → 500).
- Strong parameters: `permitted` filtering, nested/array reconstruction, `namespace`, `required` success and the mandatory-callback failure path, and the missing-callback setup error.
- POD for every public export and method, in the same commit that introduces it.

## Decisions log (from brainstorming)

- Block `app { }` form chosen specifically to avoid global state (the app is a value).
- Return-value coercion is in (local, predictable); `$c->json/text/html/redirect` sugar added for control.
- Middleware scoping via `enable` (app) + `[\@mw]` on route/group; the earlier path-scoped `enable '/p' => …` idea was dropped as too magic.
- `:placeholders` become handler signature parameters.
- The full "model" idea was dropped; validation goes to Valiant. What remains is strong parameters — a port of the StructuredParameters core.
- `required` failure resolved via a mandatory on-missing callback (resolves the B2 throw-vs-value tension).
- Two run shapes supported (`app.pl` quickstart; `lib/MyApp.pm` modulino for real apps); no framework `@INC` magic.

## Resolved

- **Arrays-of-hashes are in v1** (`+{ children => [['name','age']] }`) — the rule grammar supports scalars, nested hashes, arrays, and arrays-of-hashes (full nesting).
- **Three distributions** (see Packaging): PAGI-Tools (base, untouched), `PAGI::StructuredParameters` (the strong-params engine, its own dist), and `PAGI::Nano` (the framework, its own dist). Strong-params is built first.

## Packaging and integration (supersedes the earlier "in PAGI-Tools / on PAGI::Request" notes)

PAGI::Nano ships as its **own distribution**, not inside PAGI-Tools — for discoverability, and so people using PAGI-Tools as the base for their own frameworks are not forced to install a framework. The strong-parameters engine likewise ships as its **own distribution**, `PAGI::StructuredParameters`, rather than as methods on PAGI-Tools' `PAGI::Request`: a separate dist cannot cleanly add `$req->` methods (subclassing needs a request-class hook PAGI-Tools does not have; monkey-patching is action-at-a-distance), and param-shaping is an opinion, not a base primitive.

Three distributions, clean DAG:

- **PAGI-Tools** — unopinionated base. Depends on neither; untouched by this work.
- **PAGI::StructuredParameters** — the no-deps strong-params engine, plus `from_body/from_query/from_data($req)` adapters and a pure `new(context => …, src => …)`. Depends on PAGI-Tools (for the adapters). Independently usable.
- **PAGI::Nano** — the micro-framework. Depends on PAGI-Tools + PAGI::StructuredParameters.

Integration: Nano vends `$c` as `PAGI::Nano::Context` (a subclass of `PAGI::Context`, so still a real Context — no silo). `$c->params` is sugar that builds the engine from the request:

    package PAGI::Nano::Context;
    use parent 'PAGI::Context';
    sub params {
        my $self = shift;
        require PAGI::StructuredParameters;
        return $self->req->is_json
            ? PAGI::StructuredParameters->from_data($self->req)
            : PAGI::StructuredParameters->from_body($self->req);
    }

PAGI-Tools never learns either dist exists. `PAGI::Nano::Context` is also the home for the response sugar (`json`/`text`/`html`/`redirect`), keeping PAGI-Tools' Context bare (Endpoint handlers use `$c->response->json(...)`). OPEN: whether those four shortcuts stay Nano-only or are shared into PAGI-Tools' `Context::HTTP`.
