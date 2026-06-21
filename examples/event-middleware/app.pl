use v5.40;
use experimental 'signatures';
use Future::AsyncAwait;
use PAGI::Nano;

# Ports PAGI's 17-event-middleware to PAGI::Nano.
# Event-layer middleware can synthesize events and fold them into $receive, so the
# inner handler sees custom events on the same channel as protocol events. To
# rewrite the event channel the middleware must be an *object* with a
# ->call($scope, $receive, $send, $next) method: object middleware receives the
# real downstream app as $next and can hand it a wrapped $receive. (A bare coderef
# middleware, by convention, calls $next->() and cannot alter the channel.)
#
#     pagi-server app.pl
#     curl http://127.0.0.1:5000/

# Middleware object: injects one synthetic {type=>'tick'} event, then defers to
# the real receive.
package TickInjector {
    sub new ($class) { bless {}, $class }

    async sub call ($self, $scope, $receive, $send, $next) {
        my $ticked = 0;
        my $wrapped_receive = async sub {
            return { type => 'tick', at => 'middleware' } unless $ticked++;
            return await $receive->();
        };
        await $next->($scope, $wrapped_receive, $send);
    }
}

my $app = app {
    enable TickInjector->new;

    get '/' => async sub ($c) {
        my $event = await $c->receive->();      # sees the injected tick first
        { saw => $event->{type}, source => $event->{at} // 'protocol' };
    };
};

$app;
