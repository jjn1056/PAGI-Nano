use v5.40;
use experimental 'signatures';
use Future::AsyncAwait;
use JSON::MaybeXS qw(encode_json);
use PAGI::Nano;

# Custom SEND events: the mirror of sse-custom-events. There, a middleware folds
# custom events INTO $receive. Here, the handler emits high-level, semantic events
# and a middleware translates them OUT of $send into the wire protocol — exactly
# the mechanism PAGI's own SSE/WebSocket are built on (sse.send and websocket.send
# are custom send events a server-side layer renders).
#
# The handler speaks pure domain — { name => ..., data => ... } — and never names
# a wire format or computes metadata. The middleware owns the SSE rendering AND
# enriches every event with a server-assigned sequence number. The app is decoupled
# from the representation: this middleware is the single place the wire format and
# the enrichment live — swap it and the handler is untouched.
#
#     pagi-server app.pl
#     curl -N -H 'Accept: text/event-stream' http://127.0.0.1:5000/feed
#
# Note: this raw-$send "emit a custom event, let a middleware render it" shape fits
# the imperative ws/sse handlers. Nano's HTTP handlers return a response (it gets
# coerced), so the same pattern over a plain HTTP stream (e.g. NDJSON) would need
# an imperative HTTP handler — a boundary, not a wall.

# The middleware: translate the app's { type => 'app.event', name, data } events
# into real sse.send events, enriching each with a server-assigned sequence number
# the app never sees. Real protocol events (sse.start, ...) pass through untouched.
# Gated to the SSE scope.
my $render = async sub ($scope, $receive, $send, $next) {
    return await $next->() unless ($scope->{type} // '') eq 'sse';

    my $seq = 0;
    my $wrapped_send = async sub ($event) {
        if (($event->{type} // '') eq 'app.event') {
            $seq++;
            await $send->({
                type  => 'sse.send',
                event => $event->{name},
                data  => encode_json({ value => $event->{data}, seq => $seq }),
            });
            return;
        }
        await $send->($event);    # real protocol events pass straight through
    };

    await $next->($scope, $receive, $wrapped_send);
};

my $app = app {
    enable $render;

    # Pure domain handler: it emits semantic events and never touches the wire
    # format or the sequence numbers — those are the middleware's job.
    sse '/feed' => async sub ($c) {
        # $c->send on an SSE context is the SSE message convenience (it sends an
        # sse.send). Reach the raw send channel so we can emit our OWN event type
        # for the middleware to render.
        my $emit = $c->PAGI::Context::send;
        await $c->sse->start;
        for my $event (
            { name => 'status', data => 'online' },
            { name => 'tick',   data => 1 },
            { name => 'tick',   data => 2 },
            { name => 'status', data => 'offline' },
        ) {
            await $emit->({ type => 'app.event', %$event });
        }
    };
};

$app;
