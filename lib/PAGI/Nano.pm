package PAGI::Nano;

use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Scalar::Util ();
use Carp ();
use JSON::MaybeXS ();
use PAGI::App::Router;
use PAGI::Response;
use PAGI::Context;
use PAGI::Nano::Context::HTTP;
use PAGI::Nano::Context::WebSocket;
use PAGI::Nano::Context::SSE;

use Exporter 'import';
our @EXPORT = qw(
    app
    get post put patch del any
    group mount enable
    startup shutdown
    static not_found
    websocket sse
    name middleware
);

# Per-route attribute markers. Both sit in the arrow chain between the path and
# the handler, in any order; an arrayref is shorthand for middleware().
sub name       { my ($n) = @_; bless { name => $n }, 'PAGI::Nano::Marker::Name' }
sub middleware { bless { list => [@_] }, 'PAGI::Nano::Marker::Middleware' }

# Module-level registry mapping an assembled app coderef to its flat name->path
# table, so a parent's mount can collect a mounted Nano app's named routes (the
# app is an opaque coderef; this is the bridge across that boundary). Apps are
# created at startup and live for the process, so a stringified-coderef key is
# stable in practice.
our %APP_ROUTES;

# The dynamically-scoped current collector. app { } localizes this to a fresh
# collector for the duration of the block; the verbs register into it. No package
# globals leak between app { } invocations, so apps are values: composable,
# nestable, testable, many-per-process. This is the same local-scoped technique
# PAGI::Middleware::Builder's builder { } uses.
our $COLLECTOR;

# --- the collector ----------------------------------------------------------

sub app (&) {
    my ($block) = @_;
    local $COLLECTOR = {
        router       => PAGI::App::Router->new,
        app_mw       => [],
        startup      => [],
        shutdown     => [],
        named        => {},   # name => full path (own routes, group prefixes applied)
        nano_mounts  => [],   # { prefix => ..., app => <Nano app coderef> }
        prefix_stack => [],   # active group prefixes, for naming
    };
    $block->();
    return _assemble($COLLECTOR);
}

sub _assemble {
    my ($collector) = @_;
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

    # Flat name -> absolute-path registry: this app's own named routes plus those
    # of any mounted Nano app (prefixed, recursively via their stored tables).
    my $flat = _build_flat_routes($collector);

    return $app unless %$flat;   # nothing named anywhere -> no link machinery

    # Outermost wrapper: inject the registry on each request so $c->uri_for can
    # resolve any name from anywhere. The outermost app wins (//=), so a mounted
    # app sees the parent's fuller, mount-prefixed registry.
    my $inner = $app;
    my $wrapped = sub {
        my ($scope, $receive, $send) = @_;
        $scope->{'pagi.nano.routes'} //= $flat if ref $scope eq 'HASH';
        return $inner->($scope, $receive, $send);
    };
    $APP_ROUTES{"$wrapped"} = { flat => $flat };
    return $wrapped;
}

sub _build_flat_routes {
    my ($collector) = @_;
    my %flat = %{ $collector->{named} };
    for my $m (@{ $collector->{nano_mounts} }) {
        my $child = $APP_ROUTES{ "$m->{app}" } or next;   # non-Nano mount: no names
        for my $nm (keys %{ $child->{flat} }) {
            Carp::croak("Duplicate route name '$nm'") if exists $flat{$nm};
            $flat{$nm} = $m->{prefix} . $child->{flat}{$nm};
        }
    }
    return \%flat;
}

# Wrap $app in app-wide middleware, mirroring PAGI::App::Router's event-layer
# chain (coderef with a $next, or an object with ->call).
sub _wrap_with_middleware {
    my ($app, $mws) = @_;
    my $chain = $app;
    for my $mw (reverse @$mws) {
        my $next = $chain;
        if (ref($mw) eq 'CODE') {
            $chain = async sub {
                my ($scope, $receive, $send) = @_;
                await $mw->($scope, $receive, $send, async sub {
                    # Forward a transformed channel when the middleware passes
                    # one; otherwise continue with the inherited triple. Matches
                    # PAGI::App::Router so app-wide and route/group coderef
                    # middleware behave the same.
                    my ($s, $r, $sd) = @_ ? @_ : ($scope, $receive, $send);
                    await $next->($s, $r, $sd);
                });
            };
        }
        else {
            $chain = async sub {
                my ($scope, $receive, $send) = @_;
                await $mw->call($scope, $receive, $send, $next);
            };
        }
    }
    return $chain;
}

# --- HTTP verbs -------------------------------------------------------------

sub get    { _add_route('GET',    @_) }
sub post   { _add_route('POST',   @_) }
sub put    { _add_route('PUT',    @_) }
sub patch  { _add_route('PATCH',  @_) }
sub del    { _add_route('DELETE', @_) }

sub any {
    my ($path, @rest) = @_;
    my ($mw, $handler, $name) = _parse_route_args(@rest);
    my $wrapped = _wrap_http($handler, $path);
    $COLLECTOR->{router}->any($path, ($mw ? ($mw) : ()), $wrapped);
    _register_name($name, $path) if defined $name;
}

sub _add_route {
    my ($method, $path, @rest) = @_;
    my ($mw, $handler, $name) = _parse_route_args(@rest);
    my $wrapped = _wrap_http($handler, $path);
    $COLLECTOR->{router}->route($method, $path, ($mw ? ($mw) : ()), $wrapped);
    _register_name($name, $path) if defined $name;
}

# --- grouping, mounting, static --------------------------------------------

sub group {
    my ($prefix, @rest) = @_;
    my ($mw, $block) = _parse_route_args(@rest);
    # The router manages the prefix/middleware stack; our verbs register into the
    # same router during the block, so they are prefixed and branch-wrapped. We
    # track the prefix in parallel so named routes record their full path.
    push @{ $COLLECTOR->{prefix_stack} }, $prefix;
    $COLLECTOR->{router}->group($prefix, ($mw ? ($mw) : ()), sub { $block->() });
    pop @{ $COLLECTOR->{prefix_stack} };
}

sub mount {
    my ($prefix, $app) = @_;
    # Record Nano mounts so their named routes can be folded into this app's flat
    # registry (prefixed). Non-Nano mounts (PSGI bridges, file servers) have none.
    push @{ $COLLECTOR->{nano_mounts} }, { prefix => $prefix, app => $app }
        if exists $APP_ROUTES{"$app"};
    $COLLECTOR->{router}->mount($prefix, $app);
}

sub static {
    my ($url, $dir) = @_;
    require PAGI::App::File;
    $COLLECTOR->{router}->mount($url, PAGI::App::File->new(root => $dir));
}

# --- middleware, lifecycle, 404 --------------------------------------------

sub enable {
    my ($spec, %args) = @_;
    push @{$COLLECTOR->{app_mw}}, _normalize_middleware($spec, %args);
}

sub startup  { push @{$COLLECTOR->{startup}},  $_[0] }
sub shutdown { push @{$COLLECTOR->{shutdown}}, $_[0] }

sub not_found {
    my ($handler) = @_;
    $COLLECTOR->{router}{not_found} = _wrap_http($handler, '');
}

# --- WebSocket / SSE (imperative; not coerced) ------------------------------

sub websocket {
    my ($path, @rest) = @_;
    my ($mw, $handler, $name) = _parse_route_args(@rest);
    my $wrapped = _wrap_socket($handler, $path);
    $COLLECTOR->{router}->websocket($path, ($mw ? ($mw) : ()), $wrapped);
    _register_name($name, $path) if defined $name;
}

sub sse {
    my ($path, @rest) = @_;
    my ($mw, $handler, $name) = _parse_route_args(@rest);
    my $wrapped = _wrap_socket($handler, $path);
    $COLLECTOR->{router}->sse($path, ($mw ? ($mw) : ()), $wrapped);
    _register_name($name, $path) if defined $name;
}

sub _register_name {
    my ($name, $path) = @_;
    my $full = join('', @{ $COLLECTOR->{prefix_stack} }, $path);
    Carp::croak("Duplicate route name '$name'")
        if exists $COLLECTOR->{named}{$name};
    $COLLECTOR->{named}{$name} = $full;
}

# --- handler wrapping -------------------------------------------------------

# Extract a route's :placeholder names in path order so they can be passed to the
# handler signature after $c. Supports :name, {name}, {name:regex}, and *splat.
sub _placeholder_names {
    my ($path) = @_;
    my @names;
    while ($path =~ /\{(\w+)(?::[^}]+)?\}|\*(\w+)|:(\w+)/g) {
        push @names, defined $1 ? $1 : defined $2 ? $2 : $3;
    }
    return @names;
}

# Error handling uses Future combinators rather than try/catch so the core runs
# on Perl back to 5.18. A die in the ->then callback (e.g. an uncoercible return)
# becomes a failed Future and is handled by ->else.
sub _wrap_http {
    my ($handler, $path) = @_;
    my @names = _placeholder_names($path);
    return sub {
        my ($scope, $receive, $send) = @_;
        my $c = PAGI::Nano::Context::HTTP->new($scope, $receive, $send);
        my @params = map { $scope->{path_params}{$_} } @names;

        return _invoke_handler($handler, $c, \@params)->then(sub {
            my ($res) = @_;
            return $c->respond(_coerce($res));
        })->else(sub {
            my ($err) = @_;
            # The "featherweight die-a-respond-able" escape hatch: a thrown
            # respond-able value is sent as-is; anything else propagates and
            # becomes a 500 (rendered by enable 'ErrorHandler' or the server).
            return $c->respond($err)
                if Scalar::Util::blessed($err) && $err->can('respond');
            return Future->fail($err);
        });
    };
}

sub _wrap_socket {
    my ($handler, $path) = @_;
    my @names = _placeholder_names($path);
    return sub {
        my ($scope, $receive, $send) = @_;
        my $c = _socket_context($scope, $receive, $send);
        my @params = map { $scope->{path_params}{$_} } @names;
        return _invoke_handler($handler, $c, \@params);
    };
}

# Vend the Nano WebSocket/SSE context (which carries uri_for) by scope type,
# falling back to the stock polymorphic context for anything else.
sub _socket_context {
    my ($scope, $receive, $send) = @_;
    my $type = $scope->{type} // '';
    return PAGI::Nano::Context::WebSocket->new($scope, $receive, $send)
        if $type eq 'websocket';
    return PAGI::Nano::Context::SSE->new($scope, $receive, $send)
        if $type eq 'sse';
    return PAGI::Context->new($scope, $receive, $send);
}

# Call a handler and normalize its result to a Future, capturing a synchronous
# die from a non-async handler as a failed Future.
sub _invoke_handler {
    my ($handler, $c, $params) = @_;
    my $res = eval { $handler->($c, @$params) };
    return Future->fail($@) if $@;
    return $res if Scalar::Util::blessed($res) && $res->isa('Future');
    return Future->done($res);
}

# JSON encoder for coerced bodies. convert_blessed lets any object with a
# TO_JSON method serialize itself (e.g. a domain value nested in the response).
my $JSON = JSON::MaybeXS->new(utf8 => 1, canonical => 1, convert_blessed => 1);

# The coercion table.
sub _coerce {
    my ($res) = @_;
    if (Scalar::Util::blessed($res)) {
        return $res if $res->can('respond');    # a PAGI::Response (sent as-is)
        Carp::croak('PAGI::Nano handler returned an uncoercible '
            . ref($res) . ' object');
    }

    my $ref = ref $res;
    if ($ref eq 'HASH' || $ref eq 'ARRAY') {
        return PAGI::Response->send_raw(
            $JSON->encode($res),
            content_type => 'application/json; charset=utf-8',
        );
    }

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
sub _normalize_middleware {
    my ($spec, %args) = @_;
    return $spec if ref($spec) eq 'CODE';
    return $spec if Scalar::Util::blessed($spec) && $spec->can('call');

    Carp::croak('Invalid middleware: expected a name, instance, or coderef')
        if ref $spec;

    my $class = "PAGI::Middleware::$spec" =~ s{^.+\^}{}r;
    my $file = ($class =~ s{::}{/}gr) . '.pm';
    require $file;
    return $class->new(%args);
}

sub _normalize_middleware_list {
    my ($specs) = @_;
    return [ map { _normalize_middleware($_) } @$specs ];
}

# Parse the arguments between a verb's path and its handler: an arrayref or a
# middleware() marker contributes middleware; a name() marker names the route;
# the bare trailing coderef is the handler. Markers may appear in any order.
# Returns (\@normalized_middleware | undef, $handler, $name | undef).
sub _parse_route_args {
    my @args = @_;
    my ($handler, $name, @mw);
    for my $arg (@args) {
        my $ref = ref $arg;
        if ($ref eq 'CODE') {
            $handler = $arg;
        }
        elsif ($ref eq 'ARRAY') {
            push @mw, @$arg;
        }
        elsif (Scalar::Util::blessed($arg)
            && $arg->isa('PAGI::Nano::Marker::Middleware')) {
            push @mw, @{ $arg->{list} };
        }
        elsif (Scalar::Util::blessed($arg)
            && $arg->isa('PAGI::Nano::Marker::Name')) {
            $name = $arg->{name};
        }
        else {
            Carp::croak('Unexpected route argument: '
                . (defined $arg ? $arg : 'undef'));
        }
    }
    my $mw = @mw ? _normalize_middleware_list(\@mw) : undef;
    return ($mw, $handler, $name);
}

1;

=encoding utf8

=head1 NAME

PAGI::Nano - A compact micro-framework front door over PAGI-Tools

=head1 SYNOPSIS

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

=head1 DESCRIPTION

C<PAGI::Nano> is a compact micro-framework for demos and small apps (roughly
under 20 endpoints). "Nano" means I<compact>, not I<few features>: routing,
middleware, lifecycle, static files, streaming, WebSocket, SSE, and request
shaping are all in scope. The win is that a whole small app fits on one screen
and reads top-to-bottom.

Three principles shape it:

=over 4

=item * B<The DSL produces a value, not global state.> C<app { ... }> runs a
block-scoped collector (the same C<local>-scoped technique
L<PAGI::Middleware::Builder>'s C<builder { }> uses) and I<returns> an assembled
PAGI app. The result is composable (C<mount> it), nestable, testable, and
many-per-process.

=item * B<No silo, no cliff.> The DSL is thin sugar over the exact PAGI objects
you would use by hand — L<PAGI::Context>, L<PAGI::Response>,
L<PAGI::App::Router>, the builder, L<PAGI::Lifespan>, L<PAGI::App::File>. You can
drop to raw PAGI mid-app, and a Nano app already I<is> a PAGI app.

=item * B<Anti-magic.> The only convention is return-value coercion, which is
local and visible at the call site. C<@INC> is never touched.

=back

Strong-parameters (C<< $c->params >>) shape input; validation and persistence
are out of scope (use Valiant downstream and your own model).

=head1 EXPORTS

All of the following are exported by default:
C<app>, C<get>, C<post>, C<put>, C<patch>, C<del>, C<any>, C<group>, C<mount>,
C<enable>, C<startup>, C<shutdown>, C<static>, C<not_found>, C<websocket>,
C<sse>, C<name>, C<middleware>.

=head1 THE COLLECTOR

=head2 app

    my $app = app { ... };

Runs the block with a fresh, dynamically-scoped collector, registering whatever
the verbs declare, then assembles and returns the composed PAGI app: the router,
wrapped in any C<enable>'d middleware, wrapped in L<PAGI::Lifespan> if
C<startup>/C<shutdown> were declared. No package globals; nesting is supported.

=head1 ROUTING

=head2 get / post / put / patch / del

    get  '/path'        => sub ($c) { ... };
    post '/path'        => [\@middleware] => sub ($c) { ... };
    del  '/thing/:id'   => sub ($c, $id) { ... };

Each registers a route for the named HTTP method. C<del> is spelled without an
C<e> so it does not shadow Perl's C<delete>. An optional arrayref of middleware
may precede the handler.

A route's C<:placeholders> become the handler's parameters, in path order, after
C<$c>: C<< get '/u/:uid/p/:pid' => sub ($c, $uid, $pid) { ... } >>. The supported
placeholder forms are C<:name>, C<{name}>, C<{name:regex}>, and C<*splat>.
C<< $c->path_param('name') >> remains available.

Per-route attributes are given as markers in the same arrow chain, before the
handler, in any order: L</name> names the route for link generation, and
L</middleware> (or the C<[...]> shorthand) scopes middleware to it:

    get '/users/:id' => name('user') => middleware('Auth') => sub ($c, $id) { ... };
    get '/users/:id' => name('user') => ['Auth']          => sub ($c, $id) { ... };

=head2 any

    any '/health' => sub ($c) { ... };

Like the verbs above, but matches every HTTP method.

=head2 group

    group '/api' => [\@middleware] => sub { ...nested verbs... };

Registers the nested verbs under a shared path prefix and (optional)
branch-shared middleware. Groups nest.

=head2 mount

    mount '/admin' => $app_or_coercible;

Nests any PAGI app (coerced via C<to_app>) under a prefix — another Nano app, a
L<PAGI::Endpoint::Router>, or any coderef app.

The router does not forward lifespan events to mounted apps, so a mounted Nano
app's own C<startup>/C<shutdown> do not run; the outermost app owns lifecycle and
mounted children share its C<state>. Write mountable apps to initialize their
slice of state defensively.

=head1 RESPONSES AND COERCION

A handler returns a value, which Nano coerces:

=over 4

=item * a L<PAGI::Response> (anything that C<can('respond')>) — sent as-is.

=item * a hashref or arrayref — C<application/json> (with C<convert_blessed>, so
nested objects with a C<TO_JSON> method serialize themselves).

=item * a defined non-ref scalar — C<text/plain>.

=item * C<undef> / a bare C<return;> — a B<loud error> (becomes a 500): this
catches the forgot-to-return bug rather than sending a silent empty 200.

=item * any other reference — an error.

=back

A handler that uses C<await> (for C<< $c->params >>, streaming, etc.) must be
declared C<async sub>, which requires C<use Future::AsyncAwait> in the file
alongside C<use PAGI::Nano>. For explicit control, the inherited context sugar
C<< $c->json($data, %opts) >>, C<< $c->text >>, C<< $c->html >>,
C<< $c->redirect >> returns L<PAGI::Response> values.

A thrown respond-able value is sent as-is (the basis of C<required>'s on-missing
callback); any other exception propagates and becomes a 500, which
C<enable 'ErrorHandler'> can render.

=head1 MIDDLEWARE

=head2 enable

    enable 'GZip';
    enable 'Session', secret => '...';

Adds app-wide, event-layer middleware. A bare name (C<'GZip'>) resolves to
C<PAGI::Middleware::GZip>; a leading C<^> (C<'^My::MW'>) escapes the prefix.
Instances and coderefs (with the C<< ($scope, $receive, $send, $next) >>
signature) are also accepted. Route- and group-scoped middleware use the
C<[\@middleware]> form and are normalized the same way.

=head1 NAMED ROUTES AND LINKS

=head2 name

    get '/users/:id' => name('user') => sub ($c, $id) { ... };

A marker that names the route. Names form a single flat namespace across the
whole app (including mounted sub-apps); a duplicate name is a loud error.

=head2 middleware

    get '/x' => middleware('Auth', $coderef) => sub ($c) { ... };

A marker that scopes the given middleware to the route (the C<[...]> arrayref is
the everyday shorthand). Accepts the same names, instances, and coderefs as
L</enable>.

=head2 C<< $c->uri_for >>

    $c->uri_for('user', { id => 5 });                  # /users/5
    $c->uri_for('user', { id => 5 }, { tab => 'a' });  # /users/5?tab=a

Builds the URL for a named route, substituting path placeholders and appending
an optional query string. Because Nano injects one flat name registry onto the
request scope, C<uri_for> resolves B<any> name from B<anywhere> — including
across a C<mount> in both directions: a mounted app can link to a name defined
in its parent, and the parent can link to a name defined in the mount (paths are
returned with the mount prefix applied). C<uri_for> is available on the context
for every protocol — HTTP, WebSocket, and SSE handlers alike (see
L<PAGI::Nano::Context>).

=head1 LIFECYCLE AND SHARED STATE

=head2 startup / shutdown

    startup  async sub ($state) { ... };
    shutdown async sub ($state) { ... };

Sugar over L<PAGI::Lifespan>. C<$state> is the shared, app-lifetime state
hashref; handlers read it via C<< $c->state >>.

=head1 STATIC FILES AND CUSTOM 404

=head2 static

    static '/assets' => 'public/';

Serves files under C<public/> at C</assets/*> (wraps L<PAGI::App::File>).

=head2 not_found

    not_found sub ($c) { ... };

Sets the router's not-found handler; it is wrapped and coerced like any other
HTTP handler.

=head1 STREAMING, WEBSOCKET, SSE

WebSocket and SSE handlers are imperative and return nothing (they are not
coerced):

    websocket '/echo' => async sub ($c) {
        my $ws = $c->websocket;
        await $ws->accept;
        await $ws->each_json(async sub ($msg) { await $ws->send_json({ echo => $msg }) });
    };

    sse '/events' => async sub ($c) {
        my $s = $c->sse;
        for my $n (1 .. 5) { await $s->send("tick $n") }
    };

Streaming uses the response writer and request body stream:

    post '/upper' => async sub ($c) {
        my $in = $c->req->body_stream;
        $c->response->stream(async sub ($w) {
            while (defined(my $chunk = await $in->next_chunk)) { await $w->write(uc $chunk) }
            await $w->close;
        });
    };

=head1 STRONG PARAMETERS

C<< $c->params >> returns a request-bound L<PAGI::StructuredParameters::Request>
selecting the source by content-type. Because reading a request body is
asynchronous, its C<permitted>/C<required> are awaited. See
L<PAGI::Nano::Context::HTTP> and L<PAGI::StructuredParameters>.

=head1 RUNNING

A Nano app is an ordinary PAGI app (a coderef). Run a single file with
C<pagi-server app.pl>, where the file's last expression is the app. For a real
app, use a modulino at C<lib/MyApp.pm> whose C<to_app> returns C<app { ... }>,
and run C<pagi-server -Ilib lib/MyApp.pm>. Nano never touches C<@INC>.

=head1 SEE ALSO

L<PAGI::Tools>, L<PAGI::StructuredParameters>, L<PAGI::Nano::Context::HTTP>,
L<PAGI::App::Router>, L<PAGI::Lifespan>.

=head1 AUTHOR

John Napiorkowski C<< <jjnapiork@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2026, John Napiorkowski. This library is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

=cut
