use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use PAGI::Test::Client;
use PAGI::Nano;

# The service registry: a tiny three-scope keyword (service NAME => BUILDER)
# giving Nano apps app-scoped singletons, per-request makers, and always-new
# factories, discriminated by what the builder returns. See
# docs/superpowers/specs/2026-07-13-service-registry-design.md for the design.

subtest 'app-scoped: builders run once, before user startup, in declaration order' => sub {
    my @build_log;
    my $app = app {
        service first => sub {
            push @build_log, 'first';
            return { name => 'first' };
        };
        service second => sub {
            push @build_log, 'second';
            return { name => 'second' };
        };
        startup async sub { push @build_log, 'user-startup' };

        get '/first' => sub { my ($c) = @_; $c->service('first') };
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;

    is \@build_log, ['first', 'second', 'user-startup'],
        'both builders ran once, in declaration order, before the user startup hook';

    $client->get('/first');   # a request must not rebuild anything
    is \@build_log, ['first', 'second', 'user-startup'],
        'a request does not re-run any builder';

    $client->stop;
};

subtest 'app-scoped: every request sees the same object' => sub {
    my $app = app {
        service thing => sub { return { built_at => rand() } };
        get '/addr' => sub { my ($c) = @_; { addr => refaddr($c->service('thing')) } };
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;

    my $addr1 = $client->get('/addr')->json->{addr};
    my $addr2 = $client->get('/addr')->json->{addr};
    is $addr1, $addr2, 'same refaddr across two requests: one shared singleton';

    $client->stop;
};

subtest 'declaration order + composition: a later service gets an earlier one via $app->service' => sub {
    my $app = app {
        service first  => sub { return { name => 'first' } };
        service second => sub {
            my ($app) = @_;
            return { name => 'second', first => $app->service('first') };
        };
        get '/second' => sub { my ($c) = @_; $c->service('second') };
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;

    is $client->get('/second')->json,
        { name => 'second', first => { name => 'first' } },
        'second builder composed with the already-built first via $app->service';

    $client->stop;
};

done_testing;
