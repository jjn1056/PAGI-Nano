# NAME

PAGI::Nano - A compact micro-framework front door over PAGI-Tools

# SYNOPSIS

    use v5.40;
    use experimental 'signatures';
    use PAGI::Nano;

    my $app = app {
        startup  async sub ($state) { $state->{tasks} = [] };
        shutdown async sub ($state) { warn "served " . @{$state->{tasks}} . " tasks\n" };

        enable 'GZip';
        static '/assets' => 'public/';

        get '/'       => sub ($c) { 'PAGI::Nano' };               # String   -> text/plain
        any '/health' => sub ($c) { { ok => 1 } };               # hashref  -> JSON

        group '/api' => ['RateLimit'] => sub {
            get  '/tasks'     => sub ($c)      { $c->state->{tasks} };
            get  '/tasks/:id' => sub ($c, $id) {
                $c->state->{tasks}[$id - 1] // $c->json({ error => 'not found' }, status => 404);
            };
            post '/tasks'     => async sub ($c) {
                my $attrs = await $c->params->required(
                    'title', +{ tags => [] },
                    sub ($c, $missing) { $c->json({ error => 'missing', fields => $missing }, status => 400) },
                );
                my $tasks = $c->state->{tasks};
                push @$tasks, { id => @$tasks + 1, %$attrs };
                $c->json($tasks->[-1], status => 201);
            };
        };

        sse '/events' => async sub ($c) {
            my $s = $c->sse;
            for my $n (1 .. 5) { await $s->send("tick $n") }
        };

        not_found sub ($c) { $c->json({ error => 'no such route' }, status => 404) };
    };

    $app;   # run: pagi-server app.pl

# DESCRIPTION

`PAGI::Nano` is a compact micro-framework for demos and small apps (roughly
under 20 endpoints). "Nano" means _compact_, not _few features_: routing,
middleware, lifecycle, static files, streaming, WebSocket, SSE, and request
shaping are all in scope. The win is that a whole small app fits on one screen
and reads top-to-bottom.

Three principles shape it:

- **The DSL produces a value, not global state.** `app { ... }` runs a
block-scoped collector (the same `local`-scoped technique
[PAGI::Middleware::Builder](https://metacpan.org/pod/PAGI%3A%3AMiddleware%3A%3ABuilder)'s `builder { }` uses) and _returns_ an assembled
PAGI app. The result is composable (`mount` it), nestable, testable, and
many-per-process.
- **No silo, no cliff.** The DSL is thin sugar over the exact PAGI objects
you would use by hand — [PAGI::Context](https://metacpan.org/pod/PAGI%3A%3AContext), [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse),
[PAGI::App::Router](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3ARouter), the builder, [PAGI::Lifespan](https://metacpan.org/pod/PAGI%3A%3ALifespan), [PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile). You can
drop to raw PAGI mid-app, and a Nano app already _is_ a PAGI app.
- **Anti-magic.** The only convention is return-value coercion, which is
local and visible at the call site. `@INC` is never touched.

Strong-parameters (`$c->params`) shape input; validation and persistence
are out of scope (use Valiant downstream and your own model).

# EXPORTS

All of the following are exported by default:
`app`, `get`, `post`, `put`, `patch`, `del`, `any`, `raw`, `group`,
`mount`, `enable`, `startup`, `shutdown`, `static`, `not_found`,
`websocket`, `sse`, `name`, `middleware`, `service`, `factory`.

# THE COLLECTOR

## app

    my $app = app { ... };

Runs the block with a fresh, dynamically-scoped collector, registering whatever
the verbs declare, then assembles and returns the composed PAGI app: the router,
wrapped in any `enable`'d middleware, wrapped in [PAGI::Lifespan](https://metacpan.org/pod/PAGI%3A%3ALifespan) if
`startup`/`shutdown` were declared. No package globals; nesting is supported.

# ROUTING

## get / post / put / patch / del

    get  '/path'        => sub ($c) { ... };
    post '/path'        => [\@middleware] => sub ($c) { ... };
    del  '/thing/:id'   => sub ($c, $id) { ... };

Each registers a route for the named HTTP method. `del` is spelled without an
`e` so it does not shadow Perl's `delete`. An optional arrayref of middleware
may precede the handler.

A route's `:placeholders` become the handler's parameters, in path order, after
`$c`: `get '/u/:uid/p/:pid' => sub ($c, $uid, $pid) { ... }`. The supported
placeholder forms are `:name`, `{name}`, `{name:regex}`, and `*splat`.
`$c->path_param('name')` remains available.

Per-route attributes are given as markers in the same arrow chain, before the
handler, in any order: ["name"](#name) names the route for link generation, and
["middleware"](#middleware) (or the `[...]` shorthand) scopes middleware to it:

    get '/users/:id' => name('user') => middleware('Auth') => sub ($c, $id) { ... };
    get '/users/:id' => name('user') => ['Auth']          => sub ($c, $id) { ... };

## any

    any '/health' => sub ($c) { ... };

Like the verbs above, but matches every HTTP method.

## raw

    raw '/stream' => async sub ($c) {
        await $c->respond($c->json({ ok => 1 }));   # send your own response
    };

The imperative escape hatch. Unlike `get`/`post`/etc., a `raw` handler is
**not** coerced: it receives `$c` (and any path placeholders) and is responsible
for sending its own response — via `$c->respond`, `$c->response->stream`,
or the raw protocol. Its return value is ignored. `raw` matches every method
(the handler dispatches on `$c->method` if it cares).

This is where you drop to raw PAGI mid-app: `$c->scope`, `$c->receive`,
and `$c->send` give the underlying `($scope, $receive, $send)`, so a `raw`
handler can do anything a hand-written PAGI app can — emit custom send events for
a middleware to render, stream a bespoke protocol, and so on — while still getting
path-parameter and middleware sugar. Because it is uncoerced, **a raw handler that
never sends a response leaves the request hanging**; that is the handler's
responsibility.

## group

    group '/api' => [\@middleware] => sub { ...nested verbs... };

Registers the nested verbs under a shared path prefix and (optional)
branch-shared middleware. Groups nest.

## mount

    mount '/admin' => $app_or_coercible;

Nests any PAGI app (coerced via `to_app`) under a prefix — another Nano app, a
[PAGI::Endpoint::Router](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ARouter), or any coderef app.

The router does not forward lifespan events to mounted apps, so a mounted Nano
app's own `startup`/`shutdown` do not run; the outermost app owns lifecycle and
mounted children share its `state`. Write mountable apps to initialize their
slice of state defensively. For the same reason, `mount` croaks if the app
being mounted declared any ["SERVICES"](#services) — a service-less mounted app is fine,
and transparently shares the outermost app's services.

# RESPONSES AND COERCION

A handler returns a value, which Nano coerces:

- a [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse) (anything that `can('respond')`) — sent as-is.
- a hashref or arrayref — `application/json` (with `convert_blessed`, so
nested objects with a `TO_JSON` method serialize themselves).
- a defined non-ref scalar — `text/plain`.
- `undef` / a bare `return;` — a **loud error** (becomes a 500): this
catches the forgot-to-return bug rather than sending a silent empty 200.
- any other reference — an error.

A handler that uses `await` (for `$c->params`, streaming, etc.) must be
declared `async sub`, which requires `use Future::AsyncAwait` in the file
alongside `use PAGI::Nano`. For explicit control, the inherited context sugar
`$c->json($data, %opts)`, `$c->text`, `$c->html`,
`$c->redirect` returns [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse) values.

A thrown respond-able value is sent as-is (the basis of `required`'s on-missing
callback); any other exception propagates and becomes a 500, which
`enable 'ErrorHandler'` can render.

# MIDDLEWARE

## enable

    enable 'GZip';
    enable 'Session', secret => '...';

Adds app-wide, event-layer middleware. A bare name (`'GZip'`) resolves to
`PAGI::Middleware::GZip`; a leading `^` (`'^My::MW'`) escapes the prefix.
Instances and coderefs (with the `($scope, $receive, $send, $next)`
signature) are also accepted. Route- and group-scoped middleware use the
`[\@middleware]` form and are normalized the same way.

# NAMED ROUTES AND LINKS

## name

    get '/users/:id' => name('user') => sub ($c, $id) { ... };

A marker that names the route. Names form a single flat namespace across the
whole app (including mounted sub-apps); a duplicate name is a loud error.

## middleware

    get '/x' => middleware('Auth', $coderef) => sub ($c) { ... };

A marker that scopes the given middleware to the route (the `[...]` arrayref is
the everyday shorthand). Each element is a middleware spec — a name, an instance,
or a coderef — resolved the same way ["enable"](#enable) resolves a name. Unlike
`enable`, the route forms take no per-name constructor arguments: every element
is its own spec, so to configure a name-based middleware, pre-instantiate it
(`[ PAGI::Middleware::Session->new(secret => '...') ]`) and pass the
instance.

## `$c->uri_for`

    $c->uri_for('user', { id => 5 });                  # /users/5
    $c->uri_for('user', { id => 5 }, { tab => 'a' });  # /users/5?tab=a

Builds the URL for a named route, substituting path placeholders and appending
an optional query string. Because Nano injects one flat name registry onto the
request scope, `uri_for` resolves **any** name from **anywhere** — including
across a `mount` in both directions: a mounted app can link to a name defined
in its parent, and the parent can link to a name defined in the mount (paths are
returned with the mount prefix applied). `uri_for` is available on the context
for every protocol — HTTP, WebSocket, and SSE handlers alike (see
[PAGI::Nano::Context](https://metacpan.org/pod/PAGI%3A%3ANano%3A%3AContext)).

# LIFECYCLE AND SHARED STATE

## startup / shutdown

    startup  async sub ($state) { ... };
    shutdown async sub ($state) { ... };

Sugar over [PAGI::Lifespan](https://metacpan.org/pod/PAGI%3A%3ALifespan). `$state` is the shared, app-lifetime state
hashref; handlers read it via `$c->state`.

# SERVICES

## service / factory

    service schema => sub ($app) {
        return $schema;                              # app-scoped singleton
    };

    service params => sub ($app) {
        return sub ($ctx) {                           # per-request maker
            return Params->new($ctx->params);
        };
    };

    service stamp => sub ($app) {
        return factory sub ($ctx) {                   # per-call maker
            return Stamp->new;
        };
    };

A tiny three-scope registry. `service NAME => BUILDER` declares a
service; `$c->service(NAME)` resolves it at request time, on every
context flavor (HTTP, WebSocket, and SSE alike). The scope is chosen by what
the builder _returns_, not by any option:

- a plain value (including any blessed object, other than a `factory`
marker below) — an **app-scoped singleton**. Every `$c->service` access,
on every request, returns this same value.
- an unblessed coderef — a **per-request maker**. The first
`$c->service` access in a request calls it with the context and memoizes
the result for the rest of that request (for a WebSocket or SSE context,
"request" means that connection); later accesses in the same
request/connection return the memoized value.
- `factory sub { ... }` — a **per-call maker**. Every access calls
it with the context; nothing is memoized, so every `$c->service` call
gets a fresh object.

Builders run **eagerly, once per worker, in declaration order**, at lifespan
startup — registered before any user `startup` hook (see ["startup /
shutdown"](#startup-shutdown)). A builder that dies fails lifespan startup, so a misconfigured
service stops the worker at boot rather than surfacing on a customer's first
request. Builders are **synchronous**: a builder written as `async sub`
returns a Future, and returning a Future croaks at startup — for deferred
construction return a per-request maker (a plain coderef) or a `factory`
maker instead.

Builders **compose**: each builder receives the registry itself (`$app` in
the examples above), and `$app->service(NAME)` returns an
already-built service, letting a later service incorporate an earlier one.
Because building is eager and ordered, asking for a service declared later in
the same `app { }` block — or not declared at all — croaks, naming the
service: services can only depend on what has already been built.

Since a plain returned coderef always means "per-request maker", a service
that itself needs to hand out a fixed callback (not build one per request)
uses the per-request-maker shape as an escape hatch, returning the same
closure every time:

    service on_tick => sub ($app) {
        my $callback = sub { ... };
        return sub ($ctx) { return $callback };
    };

There is no teardown pairing in v1: a service that owns a resource needing
cleanup should register its own `shutdown` hook. There are also no generated
accessors — always `$c->service('schema')`, never `$c->schema`.

**Services and `mount`: the outermost app owns lifecycle.** Just as a mounted
Nano app's own `startup`/`shutdown` never run (see ["mount"](#mount) — the router
never forwards lifespan events into a mount), a mounted Nano app cannot
declare services at all: `mount` croaks immediately if the app being mounted
declared any, since their builders would never get a chance to run. A mounted
Nano app that declares no services of its own is unaffected — it has no
registry, so `$c->service` inside it simply resolves against whatever the
outermost app injected onto the scope, the same instances the rest of the app
sees. If lifespan forwarding to mounted apps is ever added, per-mount services
can be revisited.

## resolve\_service

    my $app = app { service schema => sub { $dbh } };
    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;                                    # runs the builders
    my $schema = PAGI::Nano::resolve_service($app, 'schema');

A test seam. `$c->service` is only reachable from inside a request handler,
so a test that wants to assert on an app-scoped service — or hand it to code
under test — otherwise has to route a request just to reach it, or reconstruct
the service by hand. `resolve_service` (not exported; call it fully qualified)
reaches the service directly: given the assembled app coderef and a name, it
returns the built value, **after lifespan startup has run** (drive it with
`PAGI::Test::Client->start`, or a lifespan `startup` event by hand). The
registry the startup hook builds is retained on the app coderef, so no request
is involved.

It resolves **app-scoped** services (a plain value or a blessed non-`factory`
object). A per-request maker or a `factory` is constructed against a request
context, which does not exist here, so for those `resolve_service` returns the
raw maker coderef / factory marker rather than a per-request instance — a test
needing the per-request value must drive a real request. Resolving an unknown
name croaks (naming it), as does calling it on an app that declared no services.

# STATIC FILES AND CUSTOM 404

## static

    static '/assets' => 'public/';

Serves files under `public/` at `/assets/*` (wraps [PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile)).

## not\_found

    not_found sub ($c) { ... };

Sets the router's not-found handler; it is wrapped and coerced like any other
HTTP handler. Write the handler as an ordinary HTTP-shaped Nano response.
For an unmatched HTTP request its response events pass through unchanged; for
an SSE scope Nano translates them to `sse.http.response.*` decline events.
Buffered and streamed byte bodies work for translated responses, but
file-backed `file`/`fh` body events are not part of the SSE or WebSocket
decline event families and croak loudly. Return bytes from the handler instead
of `send_file`.

An unmatched WebSocket can carry the custom status, headers, and body only when
the server advertises the `websocket.http.response` extension. Nano then emits
`websocket.http.response.*` events.

Without the extension Nano does not invoke the custom handler. It sends a
pre-accept `websocket.close`, asking the server to provide the portable,
body-less 403 denial response.

# STREAMING, WEBSOCKET, SSE

WebSocket and SSE handlers are imperative: like ["raw"](#raw), they own the connection,
return nothing, and are **not** coerced. Both take the same
`PATH => [\@middleware] => $handler` shape as the HTTP verbs (middleware and
["name"](#name) markers are optional and may appear in any order).

## websocket

    websocket '/echo' => async sub ($c) {
        my $ws = $c->websocket;
        await $ws->accept;
        await $ws->each_json(async sub ($msg) { await $ws->send_json({ echo => $msg }) });
    };

Registers a WebSocket route. The handler gets the [PAGI::Nano::Context::WebSocket](https://metacpan.org/pod/PAGI%3A%3ANano%3A%3AContext%3A%3AWebSocket)
context (`$c->websocket` for the socket API, `$c->uri_for` for links).

## sse

    sse '/events' => async sub ($c) {
        my $s = $c->sse;
        for my $n (1 .. 5) { await $s->send("tick $n") }
    };

Registers a Server-Sent Events route. The handler gets the
[PAGI::Nano::Context::SSE](https://metacpan.org/pod/PAGI%3A%3ANano%3A%3AContext%3A%3ASSE) context; `$c->send` is the `sse.send`
convenience, and `$c->raw_send` reaches the raw channel for custom event
types.

Streaming uses the response writer and request body stream:

    post '/upper' => async sub ($c) {
        my $in = $c->req->body_stream;
        $c->response->stream(async sub ($w) {
            while (defined(my $chunk = await $in->next_chunk)) { await $w->write(uc $chunk) }
            await $w->close;
        });
    };

# STRONG PARAMETERS

`$c->params` returns a request-bound [PAGI::StructuredParameters::Request](https://metacpan.org/pod/PAGI%3A%3AStructuredParameters%3A%3ARequest)
selecting the source by content-type. The terminal `permitted` (filter to a
whitelist) and `required` (whitelist plus a mandatory on-missing callback) are
awaited, because reading a request body is asynchronous. The chainable
`namespace` (scope the rules to a key prefix) and `flatten_array_value`
(control array flattening for form sources) shape parsing before them. See
[PAGI::Nano::Context::HTTP](https://metacpan.org/pod/PAGI%3A%3ANano%3A%3AContext%3A%3AHTTP) and [PAGI::StructuredParameters](https://metacpan.org/pod/PAGI%3A%3AStructuredParameters) for the full rule
grammar.

# RUNNING

A Nano app is an ordinary PAGI app (a coderef). Run a single file with
`pagi-server app.pl`, where the file's last expression is the app. For a real
app, use a modulino at `lib/MyApp.pm` whose `to_app` returns `app { ... }`,
and run `pagi-server -Ilib lib/MyApp.pm`. Nano never touches `@INC`.

# SEE ALSO

[PAGI::Tools](https://metacpan.org/pod/PAGI%3A%3ATools), [PAGI::StructuredParameters](https://metacpan.org/pod/PAGI%3A%3AStructuredParameters), [PAGI::Nano::Context::HTTP](https://metacpan.org/pod/PAGI%3A%3ANano%3A%3AContext%3A%3AHTTP),
[PAGI::App::Router](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3ARouter), [PAGI::Lifespan](https://metacpan.org/pod/PAGI%3A%3ALifespan), [PAGI::Nano::ServiceRegistry](https://metacpan.org/pod/PAGI%3A%3ANano%3A%3AServiceRegistry).

# AUTHOR

John Napiorkowski `<jjnapiork@cpan.org>`

# COPYRIGHT & LICENSE

Copyright 2026, John Napiorkowski. This library is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.
