use v5.40;
use experimental 'signatures';
use Future;
use Future::AsyncAwait;
use Future::IO;
use PAGI::Nano;

# Ports PAGI's 17-event-middleware to PAGI::Nano: deliver your own events through
# $receive, the composable way. A middleware owns a periodic source and folds its
# events into the $receive the inner app sees, so the app's "tick" events arrive
# on the SAME channel as the protocol events (http.request, http.disconnect). The
# app is pure: it awaits the next event and switches on type, exactly as it does
# for protocol events. Because the events ride IN $receive as ordinary typed
# events, every other middleware in the stack can act on them too.
#
# The one Nano-idiomatic adaptation vs the source: the periodic source's lifecycle
# lives in startup/shutdown (Nano's place for it) rather than the middleware
# handling the lifespan scope itself. The hard part — racing the next protocol
# event against the next tick WITHOUT cancelling the long-lived $receive — is kept
# verbatim in spirit.
#
#     pagi-server app.pl
#     curl -N http://127.0.0.1:5000/events     # NDJSON: {"tick":1} every second

# A tiny periodic source: a subscriber gets a Future that resolves on the next tick.
package TickHub {
    use experimental 'signatures';
    sub new ($class) { bless { count => 0, waiters => [] }, $class }
    sub next_tick ($self) { push @{ $self->{waiters} }, my $f = Future->new; $f }
    sub publish ($self) {
        $self->{count}++;
        # done() on a waiter cancelled by a lost race is a harmless no-op.
        $_->done($self->{count}) for splice @{ $self->{waiters} };
    }
}

# Resolve as soon as ANY of the given futures is ready, cancelling none of them.
# (Future->wait_any cancels the losers; cancelling the long-lived $receive would
# end the connection, so we watch each with on_ready instead.)
async sub await_either (@futures) {
    my $first = Future->new;
    $_->on_ready(sub { $first->done unless $first->is_ready }) for @futures;
    await $first;
    return;
}

# The middleware: wrap $receive so a tick arrives as an event alongside the
# protocol events, then hand off unchanged. Keep ONE outstanding protocol future
# across calls and race it with await_either, which never cancels it.
my $with_ticks = async sub ($scope, $receive, $send, $next) {
    my $hub = $scope->{state}{hub};
    return await $next->() unless $hub;     # e.g. the lifespan scope, before startup

    my $protocol_f;
    my $wrapped_receive = async sub {
        $protocol_f //= $receive->();       # one outstanding receive, kept alive
        my $tick_f = $hub->next_tick;
        await await_either($protocol_f, $tick_f);
        if ($protocol_f->is_ready) {        # a protocol event arrived
            my $event = $protocol_f->get;
            undef $protocol_f;              # consumed -> fetch a fresh one next time
            return $event;
        }
        return { type => 'tick', count => $tick_f->get };   # a tick, shaped as an event
    };
    await $next->($scope, $wrapped_receive, $send);
};

my $app = app {
    # The source's lifecycle lives in lifespan: one ticker per worker, shared by
    # all requests via state.
    startup async sub ($state) {
        my $hub = TickHub->new;
        $state->{hub}    = $hub;
        $state->{ticker} = (async sub {
            while (1) { await Future::IO->sleep(1); $hub->publish }
        })->();
    };
    shutdown async sub ($state) {
        $state->{ticker}->cancel if $state->{ticker};
    };

    enable $with_ticks;

    # The handler is pure: it knows nothing about hubs or sources. It streams a
    # response, then loops awaiting the next event and switches on type — a tick
    # and an http.disconnect arrive the same way, through $receive.
    get '/events' => async sub ($c) {
        $c->response->content_type('application/x-ndjson');
        $c->response->stream(async sub ($w) {
            while (1) {
                my $event = await $c->receive->();
                if ($event->{type} eq 'tick') {
                    await $w->write(qq({"tick":$event->{count}}\n));
                }
                elsif ($event->{type} eq 'http.disconnect') {
                    last;   # client went away — stop the stream
                }
                # http.request (the request body) is ignored in this demo.
            }
            await $w->close;
        });
    };
};

$app;
