use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use File::Spec ();
use FindBin ();
use Cwd ();
use PAGI::Test::Client;

# The examples themselves use modern Perl (signatures etc.), so this harness can
# only load them on a Perl new enough to parse them. The core framework (lib/ and
# the other test files) runs back to 5.18; the examples do not.
skip_all 'examples require Perl 5.40+ to load' if "$]" < 5.040;

# Every ported example under examples/ must load as a runnable PAGI app and
# behave. Examples are loaded exactly the way pagi-server loads them (set $0 and
# refresh FindBin so each example's FindBin::Bin resolves to its own directory),
# then driven with PAGI::Test::Client. Timer/loop-dependent behavior (background
# workers, keepalive ticks) needs a real event loop, so those examples are
# checked on their deterministic surfaces only.

my $examples = File::Spec->catdir($FindBin::Bin, File::Spec->updir, 'examples');

sub load_example { my ($name) = @_;
    my $file = Cwd::abs_path(File::Spec->catfile($examples, $name, 'app.pl'));
    local $0 = $file;
    FindBin::again();
    my $app = do $file;
    die "loading $name: $@" if $@;
    die "$name did not return a coderef app" unless ref($app) eq 'CODE';
    return $app;
}

subtest 'hello-http' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('hello-http'));
    is $c->get('/')->content, 'Hello, PAGI::Nano!', 'plain text';
};

subtest 'request-body' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('request-body'));
    is $c->post('/echo', body => 'ping')->content, 'ping', 'body echoed';
};

subtest 'utf8-echo' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('utf8-echo'));
    my $j = $c->get("/echo/h\x{e9}llo", query => { text => "na\x{ef}ve" })->json;
    is $j->{from_path}, "h\x{e9}llo", 'path decoded';
    is $j->{length}, 5, 'character length, not byte length';
};

subtest 'websocket-echo' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('websocket-echo'));
    $c->websocket('/', sub { my ($ws) = @_;
        $ws->send_text('hi');
        is $ws->receive_text, 'echo: hi', 'echoed';
    });
};

subtest 'static-file' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('static-file'));
    like $c->get('/')->content, qr/Served by PAGI::Nano/, 'index served at root';
    is $c->get('/index.html')->status, 200, 'named file served';
};

subtest 'lifespan-state' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('lifespan-state'), lifespan => 1);
    $c->start;
    is $c->get('/')->json->{requests}, 1, 'startup state shared';
    is $c->get('/')->json->{requests}, 2, 'state persists';
    $c->stop;
};

subtest 'streaming-response' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('streaming-response'));
    is $c->get('/stream')->content, "chunk 1\nchunk 2\nchunk 3\nchunk 4\nchunk 5\n", 'streamed';
};

subtest 'sse-broadcaster' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('sse-broadcaster'));
    $c->sse('/events', sub { my ($sse) = @_;
        my $e = $sse->receive_event;
        is $e->{event}, 'tick', 'event type';
        is $e->{id}, '1', 'event id';
        is $e->{data}, 'ping 1', 'event data';
    });
};

subtest 'connection-introspection' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('connection-introspection'));
    my $j = $c->get('/conninfo')->json;
    is $j->{scheme}, 'http', 'scheme';
    is $j->{tls}, undef, 'no TLS in plain request';
};

subtest 'bidirectional-websocket' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('bidirectional-websocket'));
    $c->websocket('/', sub { my ($ws) = @_;
        $ws->send_text('hi');
        my @got;
        for (1 .. 3) { my $m = eval { $ws->receive_text }; last unless defined $m; push @got, $m }
        ok((grep { $_ eq 'echo: hi' } @got), 'incoming branch echoes')
            or diag "frames: @got";
    });
};

subtest 'mini-framework' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('mini-framework'));
    is $c->get('/')->content, 'PAGI::Nano is the mini-framework, finished.', 'root';
    is $c->get('/hello/Ada')->content, 'Hello, Ada!', 'path param';
};

subtest 'psgi-bridge' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('psgi-bridge'));
    like $c->get('/')->content, qr/Native Nano route/, 'native route';
    is $c->get('/legacy/foo')->content, 'PSGI app saw: GET /foo', 'mounted PSGI app';
};

subtest 'background-tasks' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('background-tasks'));
    my $r = $c->post('/signup', json => { email => 'a@b.com' });
    is $r->status, 202, 'accepted immediately';
    is $r->json->{status}, 'accepted', 'response returned without waiting for bg work';
};

subtest 'flow-control' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('flow-control'));
    $c->sse('/feed', sub { my ($sse) = @_;
        is $sse->receive_event->{data}, 'reading 1', 'first reading (client keeping up)';
    });
};

subtest 'event-middleware' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('event-middleware'));
    my $j = $c->get('/')->json;
    is $j->{saw}, 'tick', 'handler saw the injected event';
    is $j->{source}, 'middleware', 'injected by the middleware';
};

subtest 'full-demo' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('full-demo'), lifespan => 1);
    $c->start;
    is $c->get('/')->json->{requests}, 1, 'lifespan state';
    is $c->post('/echo', json => { message => 'hi' })->json->{you_said}, 'hi', 'params echo';
    is $c->get('/stream')->content, "line 1\nline 2\nline 3\n", 'streaming';
    $c->websocket('/ws/echo', sub { my ($ws) = @_;
        $ws->send_text('x'); is $ws->receive_text, 'echo: x', 'ws echo';
    });
    $c->stop;
};

subtest 'contact-form' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('contact-form'));
    my $ok = $c->post('/submit', form => { email => 'a@b.com', message => 'hello' });
    is $ok->status, 201, 'valid form accepted';
    is $ok->json->{received}, { email => 'a@b.com', message => 'hello' }, 'whitelisted fields';
    my $bad = $c->post('/submit', form => { email => 'a@b.com' });
    is $bad->status, 400, 'missing field rejected';
    is $bad->json->{fields}, ['message'], 'reports the missing field';
};

subtest 'periodic-events' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('periodic-events'), lifespan => 1);
    $c->start;
    ok exists $c->get('/')->json->{ticks}, 'tick count available immediately';
    $c->stop;
};

subtest 'job-runner' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('job-runner'), lifespan => 1);
    $c->start;
    my $created = $c->post('/api/jobs', json => { label => 'resize' });
    is $created->status, 201, 'job created';
    is $created->json->{status}, 'queued', 'starts queued';
    is scalar(@{ $c->get('/api/jobs')->json }), 1, 'listed';
    is $c->get('/api/jobs/1')->json->{label}, 'resize', 'fetched by id';
    is $c->get('/api/jobs/999')->status, 404, 'unknown job 404';
    $c->stop;
};

subtest 'chat-showcase' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('chat-showcase'), lifespan => 1);
    $c->start;
    is $c->get('/api/rooms')->json, ['general'], 'seeded room';
    $c->websocket('/ws/chat', sub { my ($ws) = @_;
        $ws->send_json({ join => 'general', user => 'ada' });
        like $ws->receive_json->{system}, qr/joined general/, 'join ack';
        $ws->send_json({ text => 'hello' });
        my $b = $ws->receive_json;
        is $b->{user}, 'ada', 'broadcast user';
        is $b->{text}, 'hello', 'broadcast text';
    });
    is scalar(@{ $c->get('/api/room/general/history')->json }), 1, 'message recorded';
    $c->stop;
};

subtest 'mounted-stash-state' => sub {
    my $c = PAGI::Test::Client->new(app => load_example('mounted-stash-state'), lifespan => 1);
    $c->start;

    my $ada = $c->get('/api/hello', headers => { 'X-User' => 'Ada' })->json;
    is $ada->{user}, 'Ada', 'stash set by parent middleware reaches the mounted app';
    is $ada->{greeting}, 'Hello, Ada!', 'lifecycle greeter from startup is usable in the mount';
    is $ada->{greetings_so_far}, 1, 'lifecycle object state is live';

    my $bob = $c->get('/api/hello', headers => { 'X-User' => 'Bob' })->json;
    is $bob->{user}, 'Bob', 'stash is per-request';
    is $bob->{greetings_so_far}, 2, 'same lifecycle instance is shared across requests';

    is $c->get('/greetings')->json->{greetings_so_far}, 2,
        'parent and mounted app share the very same lifecycle object in state';
    $c->stop;
};

subtest 'run-shape examples still load' => sub {
    my $qs = load_example('quickstart');
    is ref($qs), 'CODE', 'quickstart app.pl loads';
    # tasks-modulino is covered by t/07-run-shapes.t
};

done_testing;
