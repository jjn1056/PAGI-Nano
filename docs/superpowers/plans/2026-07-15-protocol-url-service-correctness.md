# Protocol, URL, and Service Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make unmatched-route responses valid for every PAGI scope, make named-route URL generation UTF-8- and route-semantics-correct, and memoize undefined per-request service results.

**Architecture:** PAGI-Tools owns the router's portable default WebSocket decline. PAGI-Nano adapts its HTTP-shaped custom `not_found` response to the active protocol, renders named routes from decoded Perl strings into encoded URL bytes, and fixes its request cache. PAGI and PAGI-Server remain reference implementations: the official `websocket.http.response` extension and fallback already exist there.

**Tech Stack:** Perl 5.40 development environment; Future/Future::AsyncAwait; PAGI-Tools router and response primitives; PAGI-Nano; Test2::V0; core Encode; Dist::Zilla-style `Changes`/`cpanfile` metadata.

## Global Constraints

- Work in both sibling repositories:
  - Nano: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Nano`
  - Tools: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`
- Preserve all unrelated tracked and untracked work. In particular, do not edit or commit the pre-existing untracked reports/specs/plans in either repository.
- Use the Perl 5.40 environment for every test command:

```sh
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc
perlbrew use perl-5.40.0@default
```

- Nano tests must see the sibling development copies:

```sh
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/...
```

- Follow red-green-refactor: add the focused failing test, observe the expected failure, implement only that behavior, rerun focused and relevant full suites.
- Commit each task separately in the repository it changes. Never combine Tools and Nano changes in one commit.
- Do not change PAGI or PAGI-Server. The protocol extension and server support are already specified and implemented.
- Do not broaden URL behavior to array query values, missing-placeholder validation, or regex-constraint validation.
- Current re-baseline (2026-07-15): PAGI-Tools passes 151 files / 1321 tests; PAGI-Nano has 102 tests with only the lifecycle-free parent misuse in `t/07-run-shapes.t` failing under the corrected Test::Client.

---

### Task 0: Restore the Nano baseline under the stricter lifespan test client

**Files:**

- Modify: `t/07-run-shapes.t`, subtest `modulino mounts inside a larger app (no rewrite)`

**Why this is in the plan:** PAGI-Tools commit `204191e` correctly made `PAGI::Test::Client->start` reject apps that return from a requested lifespan startup without sending either completion or failure. The test's parent Nano app declares no startup/shutdown hooks or services, so Nano intentionally does not install `PAGI::Lifespan`. The mount behavior being tested does not require lifespan, and it passes without requesting it.

- [ ] **Step 1: Reproduce the current baseline failure.**

```sh
cd /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Nano
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/07-run-shapes.t
```

Expected: subtest 3 fails with `PAGI lifespan app returned without sending lifespan.startup.complete or lifespan.startup.failed`.

- [ ] **Step 2: Stop requesting unsupported lifespan in only the mount-composition subtest.** Leave the standalone modulino subtest above it unchanged because that subtest exercises the child's real startup hook.

```perl
my $client = PAGI::Test::Client->new(app => $parent);
is $client->get('/')->json, { app => 'parent' }, 'parent route';
is $client->get('/tasks/')->json, [], 'mounted modulino reachable under prefix';
```

Remove the corresponding `$client->start` and `$client->stop` calls from this subtest.

- [ ] **Step 3: Verify the focused and full Nano baseline.**

```sh
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/07-run-shapes.t
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/
```

Expected: all 3 focused subtests pass; all 11 Nano files / 102 tests pass.

- [ ] **Step 4: Commit in PAGI-Nano.**

```sh
git add t/07-run-shapes.t
git commit -m "test: stop requesting lifespan from lifecycle-free parent"
```

---

### Task 1: Make PAGI-Tools' default WebSocket decline extension-aware

**Files:**

- Modify: `../PAGI-Tools/t/app-router-scope-decline.t`
- Modify: `../PAGI-Tools/lib/PAGI/App/Router.pm`, `$send_not_found` in `to_app`
- Modify: `../PAGI-Tools/lib/PAGI/App/Router.pm` POD under `DESCRIPTION`
- Modify: `../PAGI-Tools/Changes`, current unreleased `0.002002` section

**Contract:** With `scope->{extensions}{'websocket.http.response'}` present, retain the namespaced custom 404. Without it, send `websocket.close` before acceptance so a conforming server returns the spec-defined bare 403. HTTP and SSE remain unchanged. A configured raw router `not_found` app remains responsible for its own protocol events.

- [ ] **Step 1: Split the current WebSocket test into extension-present and extension-absent cases.**

Use an advertised empty hashref exactly as the PAGI spec defines:

```perl
subtest 'unmatched WebSocket route with denial extension -> namespaced 404' => sub {
    my $router = PAGI::App::Router->new;
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({
        type       => 'websocket',
        path       => '/nope',
        extensions => { 'websocket.http.response' => {} },
    }, sub { Future->done }, $send)->get;

    is $sent->[0]{type},   'websocket.http.response.start', 'extension permits custom start';
    is $sent->[0]{status}, 404,                             'status 404';
    is $sent->[1]{type},   'websocket.http.response.body',  'extension permits custom body';
    is $sent->[1]{more},   0,                               'body closes the response';
};

subtest 'unmatched WebSocket route without denial extension -> portable close' => sub {
    my $router = PAGI::App::Router->new;
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/nope' }, sub { Future->done }, $send)->get;

    is $sent, [{ type => 'websocket.close' }],
        'close before accept asks the server for the spec-defined bare 403';
};
```

- [ ] **Step 2: Run the focused test and observe red.**

```sh
cd /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools
prove -l t/app-router-scope-decline.t
```

Expected: the no-extension test receives `websocket.http.response.start/body` instead of one `websocket.close`.

- [ ] **Step 3: Branch before constructing the namespaced response.** Use capability presence (`exists`), not truthiness, because the advertised value is an empty capability hash.

```perl
my $type = $scope->{type} // 'http';
if ($type eq 'websocket'
        && !exists(($scope->{extensions} // {})->{'websocket.http.response'})) {
    await $send->({ type => 'websocket.close' });
    return;
}

my $prefix = $type eq 'http' ? 'http.response' : "$type.http.response";
```

Keep the existing `$not_found` delegation before this default branch.

- [ ] **Step 4: Update Router POD and Tools release notes.** State that `websocket.http.response.*` is used only when advertised; otherwise an unmatched WebSocket route sends `websocket.close` and the server supplies a bare 403. Do not describe the extension as mandatory.

- [ ] **Step 5: Verify focused tests, POD, and the full Tools suite.**

```sh
prove -l t/app-router-scope-decline.t
podchecker lib/PAGI/App/Router.pm
prove -lr t
git diff --check
```

Expected: focused test has 5 passing subtests; `podchecker` reports syntax OK; full suite remains at least 151 files / 1321 tests plus the added assertion/subtest.

- [ ] **Step 6: Commit in PAGI-Tools.**

```sh
git add lib/PAGI/App/Router.pm t/app-router-scope-decline.t Changes
git commit -m "Router: fall back when WebSocket denial responses are unavailable"
```

---

### Task 2: Make Nano custom `not_found` responses protocol-aware

**Files:**

- Create: `t/11-not-found-protocols.t`
- Modify: `lib/PAGI/Nano.pm`, `not_found` plus a private send adapter helper
- Modify: `lib/PAGI/Nano.pm` POD for `not_found`
- Modify: `Changes`, current unreleased `0.001001` section

**Contract:** The custom handler continues to return ordinary HTTP-shaped Nano responses. Nano translates only the outbound response events for SSE and supported WebSockets. Unsupported WebSockets bypass the handler and send a close. Streaming `body` events are allowed; WebSocket denial `file`/`fh` events fail loudly.

- [ ] **Step 1: Create a focused event-level test harness.** Start `t/11-not-found-protocols.t` with `Test2::V0`, `Future`, `Future::AsyncAwait`, `File::Temp`, `PAGI::Response`, and `PAGI::Nano`. Use a send collector:

```perl
sub mock_send {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    return ($send, \@sent);
}

sub invoke {
    my ($app, $scope) = @_;
    my ($send, $sent) = mock_send();
    my $future = $app->($scope, sub { Future->done }, $send);
    return ($future, $sent);
}
```

- [ ] **Step 2: Add red tests for buffered responses in all four capability states.** Build one app whose handler increments a counter and returns `PAGI::Response->text('Missing', status => 404)`.

Assert:

```perl
# HTTP
['http.response.start', 'http.response.body']

# SSE
['sse.http.response.start', 'sse.http.response.body']

# WebSocket with { extensions => { 'websocket.http.response' => {} } }
['websocket.http.response.start', 'websocket.http.response.body']

# WebSocket with no extension
[{ type => 'websocket.close' }]
```

Also assert the handler count increases for HTTP, SSE, and supported WebSocket, but not for unsupported WebSocket.

- [ ] **Step 3: Add red streaming and file-form tests.** Return this streaming response for a supported WebSocket and assert translated start, two data bodies with `more => 1`, and the final `more => 0` body:

```perl
PAGI::Response->new->status(404)->stream(async sub {
    my ($writer) = @_;
    await $writer->write('one');
    await $writer->write('two');
});
```

For the file case, create a temporary file, return `PAGI::Response->new->status(404)->send_file($filename)`, call the app on a supported WebSocket scope, and assert the returned Future fails with a message matching `websocket.*file|file.*websocket`. It is acceptable that the start event was already emitted before the body variant is rejected; streaming response adapters cannot pre-inspect future body events.

- [ ] **Step 4: Run the new test and observe red.**

```sh
cd /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Nano
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/11-not-found-protocols.t
```

Expected: SSE/WS receive invalid plain `http.response.*`; unsupported WS invokes the handler; file-form WS is not rejected by Nano.

- [ ] **Step 5: Replace `not_found`'s unconditional HTTP wrapper with scope dispatch.** Keep `_wrap_http` as the one response/coercion path and adapt its send channel:

```perl
sub not_found {
    my ($handler) = @_;
    my $http_handler = _wrap_http($handler, '');

    $COLLECTOR->{router}{not_found} = sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // 'http';

        return $http_handler->($scope, $receive, $send)
            if $type eq 'http';

        Carp::croak("not_found cannot decline unsupported scope type '$type'")
            unless $type eq 'sse' || $type eq 'websocket';

        if ($type eq 'websocket'
                && !exists(($scope->{extensions} // {})->{'websocket.http.response'})) {
            return $send->({ type => 'websocket.close' });
        }

        my $prefix = $type eq 'sse'
            ? 'sse.http.response'
            : 'websocket.http.response';
        my $adapted_send = _translate_not_found_send(
            $send,
            $prefix,
            forbid_file => $type eq 'websocket',
        );
        return $http_handler->($scope, $receive, $adapted_send);
    };
}
```

The private adapter copies each event before changing it so response objects and middleware do not observe mutation:

```perl
sub _translate_not_found_send {
    my ($send, $prefix, %opts) = @_;
    return sub {
        my ($event) = @_;
        my $type = $event->{type} // '';
        Carp::croak("not_found emitted unsupported event '$type'")
            unless $type eq 'http.response.start'
                || $type eq 'http.response.body';

        if ($opts{forbid_file} && $type eq 'http.response.body'
                && (exists $event->{file} || exists $event->{fh})) {
            Carp::croak('websocket denial responses support body bytes, not file/fh bodies');
        }

        my %translated = %$event;
        $translated{type} =~ s/^http\.response/$prefix/;
        return $send->(\%translated);
    };
}
```

- [ ] **Step 6: Keep the explicit unexpected-scope guard shown above.** Router currently invokes this fallback only for HTTP/SSE/WebSocket, but the helper must croak with an unknown scope type rather than silently treating it as WebSocket. Lifespan remains ignored by Router.

- [ ] **Step 7: Update Nano POD and release notes.** Document the extension-dependent WebSocket body and portable body-less 403 fallback. Document that WebSocket denial responses reject file/fh response bodies; buffered and streamed byte bodies work.

- [ ] **Step 8: Verify focused tests, nearby regressions, and POD.**

```sh
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/11-not-found-protocols.t t/02-routing-coercion.t t/05-websocket-sse-stream.t
podchecker lib/PAGI/Nano.pm
git diff --check
```

- [ ] **Step 9: Commit in PAGI-Nano.**

```sh
git add lib/PAGI/Nano.pm t/11-not-found-protocols.t Changes
git commit -m "not_found: emit protocol-valid decline responses"
```

---

### Task 3: Render named-route URLs from UTF-8 bytes and placeholder semantics

**Files:**

- Modify: `t/09-named-routes.t`
- Modify: `lib/PAGI/Nano/Context.pm`, `uri_for` and private escaping helpers
- Modify: `lib/PAGI/Nano/Context.pm` POD under `uri_for`
- Modify: `Changes`, current unreleased `0.001001` section

**Contract:** Inputs are decoded Perl strings. Literal path text preserves RFC 3986 path characters and `/`; ordinary placeholders are one encoded segment and reject `/`; splats preserve separators while encoding each segment; query keys/values use UTF-8 percent encoding and `%20` spaces.

- [ ] **Step 1: Add `use utf8;` and red named-route tests.** Cover these exact cases:

```perl
# Ordinary value and literal path Unicode/reserved characters
'/caf%C3%A9/users/a%20b%3F%23%25'

# Query key/value Unicode and reserved characters, with sorted keys
'?caf%C3%A9=a%20b%26%3D&z=%E2%98%83'

# Splat preserves only its slash separators
'/files/caf%C3%A9/a%20b'
```

For ordinary-placeholder slash rejection, construct a context directly around a route table so the croak can be asserted without converting it into an HTTP 500:

```perl
my $ctx = bless {
    scope => { 'pagi.nano.routes' => { user => '/users/:id' } },
}, 'PAGI::Nano::Context';

my $err = dies { $ctx->uri_for('user', { id => 'a/b' }) };
like $err, qr{/.*splat|splat.*/}i,
    'ordinary placeholder rejects a path-valued input and points to splat';
```

- [ ] **Step 2: Run the focused test and observe red.**

```sh
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/09-named-routes.t
```

Expected: Unicode is encoded by code point rather than UTF-8 byte, reserved path values remain raw, and ordinary values accept `/`.

- [ ] **Step 3: Add core Encode and render the path token-by-token.** Start the module with `use Encode ();`. Replace the per-key substitution loop with:

```perl
$path = _render_path($path, $path_params);
```

Implement the renderer so missing params retain their current behavior (the unmatched token remains in the output):

```perl
sub _render_path {
    my ($template, $params) = @_;
    my $rendered = '';
    my $offset = 0;

    while ($template =~ /(\{(\w+)(?::[^}]*)?\}|\*(\w+)|:(\w+))/g) {
        # Capture all match state before an escaping helper runs another regex.
        my ($start, $end) = ($-[0], $+[0]);
        my ($token, $braced, $splat, $colon) = ($1, $2, $3, $4);
        $rendered .= _escape_path_literal(
            substr($template, $offset, $start - $offset)
        );

        my $name = defined $braced ? $braced
                 : defined $splat  ? $splat
                 :                   $colon;

        if (!exists $params->{$name}) {
            $rendered .= $token;
        }
        else {
            my $value = defined $params->{$name} ? "$params->{$name}" : '';
            if (defined $splat) {
                $rendered .= join '/', map { _uri_escape($_) }
                    split '/', $value, -1;
            }
            else {
                Carp::croak(
                    "uri_for: value for '$name' contains '/' -- use a *splat route for path-valued parameters"
                ) if index($value, '/') >= 0;
                $rendered .= _uri_escape($value);
            }
        }
        $offset = $end;
    }

    $rendered .= _escape_path_literal(substr($template, $offset));
    return $rendered;
}
```

- [ ] **Step 4: Encode Unicode to UTF-8 bytes before percent escaping.** Keep separate safe sets for route literals and inserted segments/query values:

```perl
sub _utf8_bytes {
    my ($s) = @_;
    $s = '' unless defined $s;
    return Encode::encode('UTF-8', $s, Encode::FB_CROAK());
}

sub _escape_path_literal {
    my $bytes = _utf8_bytes($_[0]);
    $bytes =~ s/([^A-Za-z0-9\-._~!\$&'()*+,;=:\@\/])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}

sub _uri_escape {
    my $bytes = _utf8_bytes($_[0]);
    $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}
```

Do not add `/` to `_uri_escape`'s safe set. The splat renderer is solely responsible for rejoining decoded slash separators.

- [ ] **Step 5: Add a regression assertion that callers must not pre-encode.** A value containing literal `%2F` must produce `%252F`, proving `%` is data and preventing ambiguous double semantics.

- [ ] **Step 6: Update Context POD and release notes.** Explicitly distinguish segment placeholders from `*splat`, say inputs are decoded strings, and say ordinary values containing `/` croak because PAGI decodes `%2F` before routing.

- [ ] **Step 7: Verify focused tests and POD.**

```sh
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/09-named-routes.t
podchecker lib/PAGI/Nano/Context.pm
git diff --check
```

- [ ] **Step 8: Commit in PAGI-Nano.**

```sh
git add lib/PAGI/Nano/Context.pm t/09-named-routes.t Changes
git commit -m "uri_for: encode UTF-8 values with route-aware semantics"
```

---

### Task 4: Memoize `undef` from per-request service makers

**Files:**

- Modify: `t/service.t`
- Modify: `lib/PAGI/Nano/ServiceRegistry.pm`, `_resolve`
- Modify: `Changes`, current unreleased `0.001001` section

**Contract:** A per-request maker runs at most once per service name per scope, regardless of whether it returns `undef`, `0`, an empty string, a reference, or a coderef. `resolve_service` remains a raw app-scoped probe and must not be routed through `_resolve`.

- [ ] **Step 1: Add a red test immediately after the existing per-request memoization tests.**

```perl
subtest 'per-request: undef maker result is still memoized by existence' => sub {
    my $maker_calls = 0;
    my $app = app {
        service maybe => sub {
            return sub {
                ++$maker_calls;
                return undef;
            };
        };
        get '/twice' => sub {
            my ($c) = @_;
            my $first  = $c->service('maybe');
            my $second = $c->service('maybe');
            return {
                both_undef => (!defined($first) && !defined($second) ? 1 : 0),
                calls      => $maker_calls,
            };
        };
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;
    is $client->get('/twice')->json,
        { both_undef => 1, calls => 1 },
        'two accesses in one request invoke an undef-returning maker once';
    is $client->get('/twice')->json,
        { both_undef => 1, calls => 2 },
        'the next request has a fresh cache and invokes it once';
    $client->stop;
};
```

- [ ] **Step 2: Run the focused test and observe red.**

```sh
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/service.t
```

Expected: the first request reports 2 calls and the second reports 4 because `//=` treats the cached `undef` as absent.

- [ ] **Step 3: Replace defined-or memoization with an existence check.**

```perl
my $scope = $ctx->{scope};
my $cache = $scope->{'pagi.nano.service_cache'} //= {};
return $cache->{$name} if exists $cache->{$name};

my $value = $raw->($ctx);
$cache->{$name} = $value;
return $value;
```

Do not alter the factory branch or app-scoped branch. Do not change `PAGI::Nano::resolve_service`; its new raw-maker identity tests deliberately cover a different seam.

- [ ] **Step 4: Add the release-note bullet and run focused plus full Nano tests.**

```sh
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/service.t
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/
git diff --check
```

- [ ] **Step 5: Commit in PAGI-Nano.**

```sh
git add lib/PAGI/Nano/ServiceRegistry.pm t/service.t Changes
git commit -m "ServiceRegistry: memoize undefined per-request values"
```

---

### Task 5: Integrate the sibling release and verify both distributions

**Files:**

- Modify: `cpanfile`, PAGI-Tools minimum version
- Modify: `Changes`, add the dependency-floor integration note to the current unreleased `0.001001` section

**Contract:** A released PAGI-Nano must install a PAGI-Tools version containing Task 1. Otherwise Nano's default unmatched-WebSocket behavior would remain invalid even though its custom `not_found` behavior is fixed.

- [ ] **Step 1: Confirm the Tools release version before flooring it.** At the current HEAD the router fix belongs in the unreleased `0.002002` section. If that version has changed by implementation time, use the actual first released version containing the Task 1 commit.

```sh
cd /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools
sed -n '1,20p' Changes
git log -1 --oneline
```

- [ ] **Step 2: Raise Nano's Tools floor.** Assuming the current release sections remain unchanged:

```perl
requires 'PAGI::Tools', '0.002002';
```

Mention in Nano `Changes` that the floor supplies extension-aware default WebSocket declines and the stricter Test::Client behavior reflected by Task 0.

- [ ] **Step 3: Run all verification from fresh command invocations.**

PAGI-Tools:

```sh
cd /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools
prove -l t/app-router-scope-decline.t
prove -lr t
podchecker lib/PAGI/App/Router.pm
git diff --check
git status --short
```

PAGI-Nano:

```sh
cd /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Nano
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/07-run-shapes.t t/09-named-routes.t t/11-not-found-protocols.t t/service.t
prove -l -I ../PAGI-Tools/lib -I ../PAGI-StructuredParameters/lib t/
podchecker lib/PAGI/Nano.pm
podchecker lib/PAGI/Nano/Context.pm
podchecker lib/PAGI/Nano/ServiceRegistry.pm
git diff --check
git status --short
```

Expected: both full suites pass; POD reports syntax OK; diff checks are silent. `git status` may still show the user's pre-existing untracked files, but it must show no unexplained files or edits created by this work.

- [ ] **Step 4: Review protocol invariants directly in the final diff.**

Confirm all of the following before claiming completion:

- WebSocket denial events are sent only when the extension key exists.
- Unsupported WebSockets send close before the Nano custom handler runs.
- SSE always receives `sse.http.response.*` for the custom decline.
- The adapter copies events and rejects WebSocket file/fh bodies.
- URL escaping operates on UTF-8 bytes; ordinary params never preserve `/`; splats alone preserve it.
- Query sorting and `%20` spaces remain compatible.
- The service cache uses `exists`; the new `resolve_service` seam remains unchanged.
- No PAGI or PAGI-Server production files changed.

- [ ] **Step 5: Commit the Nano dependency floor.**

```sh
git add cpanfile Changes
git commit -m "deps: require extension-aware PAGI-Tools router"
```

## Self-Review Notes

- **Approved-design coverage:** Tools default decline (Task 1); Nano custom protocol adaptation including streaming/file rejection (Task 2); UTF-8 route generation and segment/splat distinction (Task 3); undefined service memoization (Task 4); release integration and full verification (Task 5).
- **Concurrent-change impact:** Task 0 accounts for PAGI-Tools' newly strict lifespan client. Task 4 explicitly preserves the newly added `resolve_service` raw-return contract. Current `0.001001` and `0.002002` release-note sections are used instead of inventing new version headings.
- **Spec alignment:** No new extension is introduced. The plan consumes the official `websocket.http.response` capability and its `websocket.close` fallback. PAGI's decoded `scope->{path}` rule is why ordinary placeholder values containing `/` croak rather than becoming `%2F`.
- **Scope control:** No array query semantics, required-param enforcement, route-regex reverse validation, mounted lifespan forwarding, server changes, or spec changes are included.
- **No placeholders:** Every task names exact files, focused tests, expected red/green behavior, implementation shape, verification commands, and a commit boundary. The only conditional is the dependency version check, which must follow the actual Tools release containing Task 1.
