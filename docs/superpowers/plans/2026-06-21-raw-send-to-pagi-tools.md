# Move `raw_send` to PAGI-Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the `raw_send` accessor from the PAGI::Nano context mixin down into PAGI-Tools' base `PAGI::Context`, so it is an unopinionated base primitive available to every PAGI context (and inherited by Nano for free).

**Architecture:** `raw_send` is literally `shift->{send}` — it returns the underlying raw `$send` coderef regardless of context type. The base `PAGI::Context` already exposes `scope`/`receive`/`send` as siblings, but `PAGI::Context::SSE` overrides `send` with the `sse.send` convenience, hiding the raw channel. Adding `raw_send` to the base gives a stable, override-proof accessor for all contexts. Nano's contexts descend from the stock PAGI contexts, so they inherit it automatically; the duplicate in the Nano mixin is then deleted.

**Tech Stack:** Perl (PAGI-Tools targets 5.18), Test2::V0, Dist::Zilla. Two local sibling distributions: `~/Desktop/PAGI-Tools` and `~/Desktop/PAGI-Nano` (depends on PAGI-Tools + PAGI-StructuredParameters).

## Global Constraints

- **Perl environment:** before ANY `perl`/`prove`, run `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default`. Never use system perl.
- **PAGI-Tools lib must stay Perl 5.18-compatible:** no signatures; match the surrounding `sub name { shift->{...} }` style in `PAGI::Context`.
- **PAGI-Nano core (lib/, t/) must stay Perl 5.18-compatible:** no signatures, no `use v5.40`. (This change only deletes from Nano, so this is preserved.)
- **PAGI-Tools change lands on `main`** (consistent with the earlier coderef-middleware fix the user directed onto main). Working tree is clean before starting.
- **Test invocation needs the sibling libs on `@INC`:** PAGI-Tools tests run with `prove -l`; PAGI-Nano tests run with `prove -l -I ~/Desktop/PAGI-Tools/lib -I ~/Desktop/PAGI-StructuredParameters/lib`.
- **Commit author/trailers:** commit with `git -c user.name='John Napiorkowski' -c user.email='john.napiorkowski@infillion.com'` and end commit messages with the repo's session trailers (`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and the `Claude-Session:` line) as used in recent commits.

---

## File Structure

- **PAGI-Tools** (`~/Desktop/PAGI-Tools`)
  - Modify `lib/PAGI/Context.pm` — add `sub raw_send` + POD next to `send`.
  - Create `t/context/raw-send.t` — test `raw_send` across HTTP/SSE/WebSocket contexts (the SSE case is the one that matters, since SSE overrides `send`).
  - Modify `Changes` — add a bullet under the unreleased section.
- **PAGI-Nano** (`~/Desktop/PAGI-Nano`)
  - Modify `lib/PAGI/Nano/Context.pm` — delete the now-redundant `raw_send` sub and its POD (Nano inherits it from the base).

---

### Task 1: Add `raw_send` to PAGI-Tools base `PAGI::Context`

**Files:**
- Create: `~/Desktop/PAGI-Tools/t/context/raw-send.t`
- Modify: `~/Desktop/PAGI-Tools/lib/PAGI/Context.pm` (add `sub raw_send` after `sub send` at line 345; add POD after the `=head2 send` block, before the `=cut` at ~line 343)
- Modify: `~/Desktop/PAGI-Tools/Changes`

**Interfaces:**
- Produces: `$ctx->raw_send` — a method on `PAGI::Context` (and therefore every subclass) returning the raw `$send` coderef (`$self->{send}`), regardless of whether the subclass overrides `send`. No arguments. Returns the coderef itself (not a Future).

- [ ] **Step 1: Write the failing test**

Create `~/Desktop/PAGI-Tools/t/context/raw-send.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use PAGI::Context;

# raw_send returns the underlying $send coderef on every context type — including
# the SSE context, whose ->send is overridden with the sse.send convenience.

my $send = sub { };

subtest 'SSE context: raw_send bypasses the ->send override' => sub {
    my $ctx = PAGI::Context->new({ type => 'sse' }, sub { }, $send);
    isa_ok $ctx, ['PAGI::Context::SSE'];
    ok $ctx->raw_send == $send, 'raw_send is the underlying send coderef';
    # ->send is the SSE convenience here, not the raw coderef
    ok ref($ctx->can('send')) eq 'CODE', 'send is still available (the SSE convenience)';
};

subtest 'HTTP context: raw_send equals the raw send' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', method => 'GET' }, sub { }, $send);
    isa_ok $ctx, ['PAGI::Context::HTTP'];
    ok $ctx->raw_send == $send, 'raw_send is the send coderef';
    ok $ctx->send    == $send, 'HTTP send is already the raw coderef';
};

subtest 'WebSocket context: raw_send equals the raw send' => sub {
    my $ctx = PAGI::Context->new({ type => 'websocket' }, sub { }, $send);
    isa_ok $ctx, ['PAGI::Context::WebSocket'];
    ok $ctx->raw_send == $send, 'raw_send is the send coderef';
};

done_testing;
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default
cd ~/Desktop/PAGI-Tools && prove -l t/context/raw-send.t
```
Expected: FAIL — `Can't locate object method "raw_send" via package "PAGI::Context::SSE"`.

- [ ] **Step 3: Add the method and POD to `lib/PAGI/Context.pm`**

Add the method immediately after `sub send { shift->{send} }` (currently line 345):

```perl
sub raw_send { shift->{send} }
```

Add this POD block immediately after the existing `=head2 send` section and before its closing `=cut` (i.e., insert before the `=cut` near line 343):

```pod
=head2 raw_send

    my $send = $ctx->raw_send;

Returns the raw C<$send> coderef, the same as L</send> on the base context.
Unlike C<send>, subclasses do not override C<raw_send>: the SSE context overrides
C<send> with the C<sse.send> convenience, so reach for C<raw_send> when you need
the underlying channel — for example to emit your own event types for a
middleware to render.

```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ~/Desktop/PAGI-Tools && prove -l t/context/raw-send.t
```
Expected: PASS (3 subtests).

- [ ] **Step 5: Run the broader context + full suite to confirm no regression**

```bash
cd ~/Desktop/PAGI-Tools && prove -lr t/context/ && prove -lr t/
```
Expected: all PASS (the full suite was 1198 tests + this new file).

- [ ] **Step 6: Confirm 5.18-compatibility (compiles, no signatures introduced)**

```bash
cd ~/Desktop/PAGI-Tools && perl -I lib -c lib/PAGI/Context.pm
```
Expected: `lib/PAGI/Context.pm syntax OK`. (Visually confirm the added line uses `shift->{send}`, not a signature.)

- [ ] **Step 7: Add a Changes entry**

In `~/Desktop/PAGI-Tools/Changes`, under the existing unreleased bullets (above the `0.002000` line), add:

```
  - PAGI::Context - new raw_send accessor returning the raw $send coderef on any
    context type. The base ->send already is the raw send, but PAGI::Context::SSE
    overrides ->send with the sse.send convenience; raw_send is the stable,
    override-proof accessor for the underlying channel.
```

- [ ] **Step 8: Commit**

```bash
cd ~/Desktop/PAGI-Tools && git add -A && git -c user.name='John Napiorkowski' -c user.email='john.napiorkowski@infillion.com' commit -m "PAGI::Context: add raw_send accessor

raw_send returns the raw \$send coderef on any context type. The base ->send
already is the raw send, but PAGI::Context::SSE overrides ->send with the
sse.send convenience, hiding the raw channel; raw_send is the stable,
override-proof accessor (useful for emitting custom send events a middleware
renders, and to PAGI::Endpoint handlers and raw apps, not just PAGI::Nano).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RrFSycmfnVit6NsqMBDj9b"
```

---

### Task 2: Delete the redundant `raw_send` from the Nano mixin

**Files:**
- Modify: `~/Desktop/PAGI-Nano/lib/PAGI/Nano/Context.pm` (remove the `raw_send` sub at lines 14-17 and its `=head2 raw_send` POD block at ~lines 78-90)

**Interfaces:**
- Consumes: `PAGI::Context::raw_send` from Task 1 (inherited by `PAGI::Nano::Context::{HTTP,SSE,WebSocket}` via their stock-context parents).
- Produces: nothing new; `$c->raw_send` continues to work on Nano contexts, now sourced from the base.

- [ ] **Step 1: Confirm the Nano suite currently passes (baseline, raw_send from the mixin)**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default
cd ~/Desktop/PAGI-Nano && prove -l -I ~/Desktop/PAGI-Tools/lib -I ~/Desktop/PAGI-StructuredParameters/lib t/08-examples.t
```
Expected: PASS (the `custom-send-events` subtest exercises `$c->raw_send` on both SSE and HTTP Nano contexts).

- [ ] **Step 2: Remove the `raw_send` sub from `lib/PAGI/Nano/Context.pm`**

Delete this block (currently lines 13-17 — the comment and the sub):

```perl
# The raw $send coderef, on any context type. The base PAGI::Context's ->send is
# already this, but the SSE/WebSocket contexts override ->send with a protocol
# convenience (sse.send / websocket.send), so reach for raw_send when you need to
# emit your own events for a middleware to render.
sub raw_send { shift->{send} }
```

- [ ] **Step 3: Remove the `raw_send` POD from `lib/PAGI/Nano/Context.pm`**

Delete this POD block (the `=head2 raw_send` section, currently ~lines 78-90):

```pod
=head2 raw_send

    my $emit = $c->raw_send;
    await $emit->({ type => 'app.event', ... });

Returns the raw C<$send> coderef regardless of context type. The base HTTP
context's C<< $c->send >> already is the raw send, but the WebSocket and SSE
contexts override C<< $c->send >> with a protocol convenience
(C<websocket.send> / C<sse.send>); C<raw_send> gives the underlying channel on
all of them, so a handler can emit its own event types for a middleware to
render (see the C<custom-send-events> example).

```

- [ ] **Step 4: Run the Nano suite to verify `raw_send` is now inherited from the base**

```bash
cd ~/Desktop/PAGI-Nano && prove -l -I ~/Desktop/PAGI-Tools/lib -I ~/Desktop/PAGI-StructuredParameters/lib t/
```
Expected: all PASS (69 tests). The `custom-send-events` subtest passing proves `$c->raw_send` still resolves — now via `PAGI::Context::raw_send`.

- [ ] **Step 5: Confirm the Nano mixin still compiles + is 5.18-compatible**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3
perl -I ~/Desktop/PAGI-Nano/lib -I /tmp/pagi-stubs -c ~/Desktop/PAGI-Nano/lib/PAGI/Nano/Context.pm
```
Expected: `...Context.pm syntax OK`. (If `/tmp/pagi-stubs` is absent, recreate the four stub packages used earlier: `PAGI/Context.pm`, `PAGI/Context/HTTP.pm`, `PAGI/Context/SSE.pm`, `PAGI/Context/WebSocket.pm`, each a one-line `package …; our @ISA=('PAGI::Context'); 1;` — the base one being just `package PAGI::Context; sub new { bless {}, shift } 1;`.)

- [ ] **Step 6: Podcheck the mixin (POD still well-formed after removal)**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default
cd ~/Desktop/PAGI-Nano && podchecker lib/PAGI/Nano/Context.pm
```
Expected: `lib/PAGI/Nano/Context.pm pod syntax OK.`

- [ ] **Step 7: Commit**

```bash
cd ~/Desktop/PAGI-Nano && git add -A && git -c user.name='John Napiorkowski' -c user.email='john.napiorkowski@infillion.com' commit -m "Nano context: inherit raw_send from PAGI::Context

raw_send is an unopinionated base primitive (it returns the raw \$send), so it
now lives on PAGI::Context in PAGI-Tools and Nano's contexts inherit it. Removes
the duplicate from the Nano mixin; \$c->raw_send is unchanged for callers (the
custom-send-events example still uses it on both the SSE and HTTP contexts).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RrFSycmfnVit6NsqMBDj9b"
```

---

## Notes / Risks

- **MRO sanity:** `PAGI::Nano::Context::SSE` has `@ISA = ('PAGI::Context::SSE', 'PAGI::Nano::Context')`. With `raw_send` on `PAGI::Context` (parent of `PAGI::Context::SSE`), Perl's default DFS finds it via the first parent chain before reaching the mixin — so removing it from the mixin cannot shadow or change behavior. Task 2 Step 4 verifies this empirically.
- **No behavior change for callers:** `raw_send` returns the same coderef; only its definition site moves.
- **Bonus reach:** once on the base, `PAGI::Endpoint` handlers and hand-written PAGI apps using `PAGI::Context::SSE` directly also get `raw_send` — the original motivation for moving it down.
