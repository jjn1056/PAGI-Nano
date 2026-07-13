# PAGI::Nano service registry — design

John's proposal (2026-07-13), refined in discussion. Three scopes, one keyword,
scope declared by what the builder returns:

```perl
# per app (really: per worker — builders run at lifespan startup, post-fork)
service schema => sub ($app) {
  return $schema;
};

# per request: built on first $c->service('params') in a request, memoized
service params => sub ($app) {
  return sub ($ctx) {
    return Params->new($ctx->params);
  };
};

# always new: fresh object on every $c->service('stamp') call
service stamp => sub ($app) {
  return factory sub ($ctx) {
    return Stamp->new;
  };
};
```

## Semantics (all binding)

1. **Declaration.** `service NAME => BUILDER` is a new `app { }` keyword,
   exported alongside the verbs. Registers `[NAME, BUILDER]` into the
   collector **in declaration order**. Croaks at declaration time on a
   duplicate NAME within the same `app { }` block, and when called outside
   an `app { }` block (match how the existing verbs guard).

2. **Instantiation is eager, per worker, in declaration order.** At assemble
   time, if any services were declared, a startup hook is registered BEFORE
   any user `startup` hooks. It runs every builder in declaration order,
   passing the registry object as the single argument (`$app` in the
   examples). A builder that dies fails lifespan startup — the worker fails
   at boot, not on a customer request.

3. **Scope discrimination by return value:**
   - plain value (including any blessed object that is not the factory
     marker) → app-scoped singleton; every access returns it.
   - unblessed coderef → per-request maker. First access in a request calls
     it with the context (`$ctx`/`$c`); result is memoized for that request
     (for a websocket/SSE context, "request" = that connection). Subsequent
     accesses in the same request return the memoized object.
   - `factory sub {...}` → per-call maker. Every access calls it with the
     context; nothing is memoized. `factory` is a tiny exported marker:
     it blesses/wraps the coderef so instantiation can tell "coderef meaning
     per-request" from "coderef meaning always-new". Croaks if its argument
     is not a coderef.

4. **Builders compose.** Inside a builder, `$app->service('name')` returns an
   ALREADY-BUILT service. Asking for one declared later (or never) croaks
   with a message naming the service and stating that services build in
   declaration order. (Eager + ordered = the whole cycle policy.)

5. **Request-time access: `$c->service(NAME)`** on every Nano context flavor
   (HTTP, WebSocket, SSE). Unknown NAME croaks. The registry travels to the
   context the same way the named-routes table does: the assembled app's
   outer wrapper injects it into `$scope`. Use plain assignment (NOT `//=`):
   a mounted Nano app's own services must win for requests routed into it —
   the innermost app's wrapper runs last before its handlers.

6. **Per-request memoization cache** lives on the per-request `$scope` hash,
   sub-keyed by the registry's refaddr, so a parent app and a mounted app
   that both define a service of the same name never share or clobber
   memoized instances within one traversal.

7. **App-scoped coderef values** (rare): a builder returning a coderef always
   means per-request. The documented escape hatch is a per-request maker
   returning the same closure: `service cb => sub ($app) { my $cb = ...;
   return sub ($ctx) { $cb } }`. POD note, not an API knob.

8. **Teardown:** none in v1. POD notes that services needing cleanup should
   register a `shutdown` hook themselves (the hook keyword already exists).

9. **No generated accessors** in v1 (`$c->service('schema')`, never
   `$c->schema`) — so no namespace guard is needed beyond the duplicate
   check.

## Non-goals (v1)

Lazy app-scoped services, test-time overrides, generated accessors,
teardown pairing, dependency graphs beyond declaration order.
