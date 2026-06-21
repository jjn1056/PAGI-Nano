use v5.40;
use experimental 'signatures';
use Future::AsyncAwait;
use PAGI::Nano;

# Ports PAGI's 17-event-middleware to PAGI::Nano.
# Event-layer middleware can synthesize events and fold them into $receive, so the
# inner handler sees custom events on the same channel as protocol events. A
# coderef middleware (signature $scope, $receive, $send, $next) wraps $receive to
# inject a one-off {type=>'tick'} event, then continues by passing the wrapped
# channel to $next. The handler reads the raw event channel via $c->receive.
#
#     pagi-server app.pl
#     curl http://127.0.0.1:5000/

my $inject_tick = async sub ($scope, $receive, $send, $next) {
    my $ticked = 0;
    my $wrapped_receive = async sub {
        return { type => 'tick', at => 'middleware' } unless $ticked++;
        return await $receive->();
    };
    await $next->($scope, $wrapped_receive, $send);   # continue with the wrapped channel
};

my $app = app {
    enable $inject_tick;

    get '/' => async sub ($c) {
        my $event = await $c->receive->();      # sees the injected tick first
        { saw => $event->{type}, source => $event->{at} // 'protocol' };
    };
};

$app;
