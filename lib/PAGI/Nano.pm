package PAGI::Nano;

use v5.40;
use experimental 'signatures';
use Future::AsyncAwait;
use Scalar::Util ();
use Carp ();
use PAGI::App::Router;
use PAGI::Response;
use PAGI::Context;
use PAGI::Nano::Context::HTTP;

use Exporter 'import';
our @EXPORT = qw(
    app
    get post put patch del any
    group mount enable
    startup shutdown
    static not_found
    websocket sse
);

# The dynamically-scoped current collector. app { } localizes this to a fresh
# collector for the duration of the block; the verbs register into it. No package
# globals leak between app { } invocations, so apps are values: composable,
# nestable, testable, many-per-process. This is the same local-scoped technique
# PAGI::Middleware::Builder's builder { } uses.
our $COLLECTOR;

# --- the collector ----------------------------------------------------------

sub app :prototype(&) ($block) {
    local $COLLECTOR = {
        router   => PAGI::App::Router->new,
        app_mw   => [],
        startup  => [],
        shutdown => [],
    };
    $block->();
    return _assemble($COLLECTOR);
}

sub _assemble ($collector) {
    my $app = $collector->{router}->to_app;

    $app = _wrap_with_middleware($app, $collector->{app_mw})
        if @{$collector->{app_mw}};

    if (@{$collector->{startup}} || @{$collector->{shutdown}}) {
        require PAGI::Lifespan;
        my $lifespan = PAGI::Lifespan->new(app => $app);
        $lifespan->on_startup($_)  for @{$collector->{startup}};
        $lifespan->on_shutdown($_) for @{$collector->{shutdown}};
        $app = $lifespan->to_app;
    }

    return $app;
}

# Wrap $app in app-wide middleware, mirroring PAGI::App::Router's event-layer
# chain (coderef with a $next, or an object with ->call).
sub _wrap_with_middleware ($app, $mws) {
    my $chain = $app;
    for my $mw (reverse @$mws) {
        my $next = $chain;
        if (ref($mw) eq 'CODE') {
            $chain = async sub ($scope, $receive, $send) {
                await $mw->($scope, $receive, $send, async sub {
                    await $next->($scope, $receive, $send);
                });
            };
        }
        else {
            $chain = async sub ($scope, $receive, $send) {
                await $mw->call($scope, $receive, $send, $next);
            };
        }
    }
    return $chain;
}

# --- HTTP verbs -------------------------------------------------------------

sub get    ($path, @rest) { _add_route('GET',    $path, @rest) }
sub post   ($path, @rest) { _add_route('POST',   $path, @rest) }
sub put    ($path, @rest) { _add_route('PUT',    $path, @rest) }
sub patch  ($path, @rest) { _add_route('PATCH',  $path, @rest) }
sub del    ($path, @rest) { _add_route('DELETE', $path, @rest) }

sub any ($path, @rest) {
    my ($mw, $handler) = _split_mw_handler(@rest);
    my $wrapped = _wrap_http($handler, $path);
    $COLLECTOR->{router}->any($path, ($mw ? ($mw) : ()), $wrapped);
}

sub _add_route ($method, $path, @rest) {
    my ($mw, $handler) = _split_mw_handler(@rest);
    my $wrapped = _wrap_http($handler, $path);
    $COLLECTOR->{router}->route($method, $path, ($mw ? ($mw) : ()), $wrapped);
}

# --- grouping, mounting, static --------------------------------------------

sub group ($prefix, @rest) {
    my ($mw, $block) = _split_mw_handler(@rest);
    # The router manages the prefix/middleware stack; our verbs register into the
    # same router during the block, so they are prefixed and branch-wrapped.
    $COLLECTOR->{router}->group($prefix, ($mw ? ($mw) : ()), sub { $block->() });
}

sub mount ($prefix, $app) {
    $COLLECTOR->{router}->mount($prefix, $app);
}

sub static ($url, $dir) {
    require PAGI::App::File;
    $COLLECTOR->{router}->mount($url, PAGI::App::File->new(root => $dir));
}

# --- middleware, lifecycle, 404 --------------------------------------------

sub enable ($spec, %args) {
    push @{$COLLECTOR->{app_mw}}, _normalize_middleware($spec, %args);
}

sub startup  ($cb) { push @{$COLLECTOR->{startup}},  $cb }
sub shutdown ($cb) { push @{$COLLECTOR->{shutdown}}, $cb }

sub not_found ($handler) {
    $COLLECTOR->{router}{not_found} = _wrap_http($handler, '');
}

# --- WebSocket / SSE (imperative; not coerced) ------------------------------

sub websocket ($path, @rest) {
    my ($mw, $handler) = _split_mw_handler(@rest);
    my $wrapped = _wrap_socket($handler, $path);
    $COLLECTOR->{router}->websocket($path, ($mw ? ($mw) : ()), $wrapped);
}

sub sse ($path, @rest) {
    my ($mw, $handler) = _split_mw_handler(@rest);
    my $wrapped = _wrap_socket($handler, $path);
    $COLLECTOR->{router}->sse($path, ($mw ? ($mw) : ()), $wrapped);
}

# --- handler wrapping -------------------------------------------------------

# Extract a route's :placeholder names in path order so they can be passed to the
# handler signature after $c. Supports :name, {name}, {name:regex}, and *splat.
sub _placeholder_names ($path) {
    my @names;
    while ($path =~ /\{(\w+)(?::[^}]+)?\}|\*(\w+)|:(\w+)/g) {
        push @names, $1 // $2 // $3;
    }
    return @names;
}

sub _wrap_http ($handler, $path) {
    my @names = _placeholder_names($path);
    return async sub ($scope, $receive, $send) {
        my $c = PAGI::Nano::Context::HTTP->new($scope, $receive, $send);
        my @params = map { $scope->{path_params}{$_} } @names;

        my $response;
        try {
            my $res = $handler->($c, @params);
            $res = await $res if Scalar::Util::blessed($res) && $res->isa('Future');
            $response = _coerce($res);
        }
        catch ($err) {
            # The "featherweight die-a-respond-able" escape hatch: a thrown
            # respond-able value is sent as-is; anything else propagates and
            # becomes a 500 (rendered by enable 'ErrorHandler' or the server).
            die $err
                unless Scalar::Util::blessed($err) && $err->can('respond');
            $response = $err;
        }

        await $c->respond($response);
    };
}

sub _wrap_socket ($handler, $path) {
    my @names = _placeholder_names($path);
    return async sub ($scope, $receive, $send) {
        my $c = PAGI::Context->new($scope, $receive, $send);
        my @params = map { $scope->{path_params}{$_} } @names;
        my $res = $handler->($c, @params);
        await $res if Scalar::Util::blessed($res) && $res->isa('Future');
        return;
    };
}

# The coercion table.
sub _coerce ($res) {
    if (Scalar::Util::blessed($res)) {
        return $res if $res->can('respond');    # a PAGI::Response (sent as-is)
        Carp::croak('PAGI::Nano handler returned an uncoercible '
            . ref($res) . ' object');
    }

    my $ref = ref $res;
    return PAGI::Response->json($res) if $ref eq 'HASH' || $ref eq 'ARRAY';

    Carp::croak("PAGI::Nano handler returned an uncoercible $ref reference")
        if $ref;

    Carp::croak('PAGI::Nano handler returned no response '
        . '(did the handler forget to return a value?)')
        unless defined $res;

    return PAGI::Response->text($res);
}

# --- middleware normalization ----------------------------------------------

# Turn a middleware spec (name string, instance, or coderef) into something the
# router/chain accepts: a coderef ($scope,$receive,$send,$next) or an object
# with ->call. Names are resolved the way `enable` resolves them.
sub _normalize_middleware ($spec, %args) {
    return $spec if ref($spec) eq 'CODE';
    return $spec if Scalar::Util::blessed($spec) && $spec->can('call');

    Carp::croak('Invalid middleware: expected a name, instance, or coderef')
        if ref $spec;

    my $class = "PAGI::Middleware::$spec" =~ s{^.+\^}{}r;
    my $file = ($class =~ s{::}{/}gr) . '.pm';
    require $file;
    return $class->new(%args);
}

sub _normalize_middleware_list ($specs) {
    return [ map { _normalize_middleware($_) } @$specs ];
}

# Split (\@middleware, $target) or ($target); normalize any middleware names.
sub _split_mw_handler (@rest) {
    if (@rest >= 2 && ref($rest[0]) eq 'ARRAY') {
        my ($mw, $target) = @rest;
        return (_normalize_middleware_list($mw), $target);
    }
    return (undef, $rest[0]);
}

1;
