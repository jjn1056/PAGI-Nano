use v5.40;
use experimental 'signatures';
use Test2::V0;
use File::Spec ();
use FindBin ();
use PAGI::Test::Client;
use PAGI::Nano;

# The two documented run shapes: a single-file app.pl whose last expression is
# the app (what pagi-server loads via `do`), and a lib/MyApp.pm modulino that is
# dual-use (to_app for tests, mountable into a larger app).

my $examples = File::Spec->catdir($FindBin::Bin, File::Spec->updir, 'examples');

subtest 'quickstart app.pl loads as a runnable PAGI app' => sub {
    my $file = File::Spec->catfile($examples, 'quickstart', 'app.pl');
    my $app  = do $file;
    die "load error: $@" if $@;
    is ref($app), 'CODE', 'app.pl returns a coderef app (pagi-server contract)';

    my $client = PAGI::Test::Client->new(app => $app);
    is $client->get('/')->content, 'Hello from PAGI::Nano', 'root responds';
    is $client->get('/hello/world')->json, { hello => 'world' }, 'path param works';
};

subtest 'modulino is dual-use: to_app for tests' => sub {
    local @INC = (File::Spec->catdir($examples, 'tasks-modulino', 'lib'), @INC);
    require MyApp;
    my $app = MyApp->to_app;
    is ref($app), 'CODE', 'MyApp->to_app returns a coderef app';

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;
    is $client->get('/')->json, [], 'starts with no tasks';
    my $created = $client->post('/', json => { title => 'Write docs', tags => ['a'] });
    is $created->status, 201, 'created';
    is $created->json, { id => 1, title => 'Write docs', tags => ['a'] }, 'task shaped';
    $client->stop;
};

subtest 'modulino mounts inside a larger app (no rewrite)' => sub {
    local @INC = (File::Spec->catdir($examples, 'tasks-modulino', 'lib'), @INC);
    require MyApp;

    my $parent = app {
        get '/'      => sub ($c) { { app => 'parent' } };
        mount '/tasks' => MyApp->to_app;
    };

    my $client = PAGI::Test::Client->new(app => $parent, lifespan => 1);
    $client->start;
    is $client->get('/')->json, { app => 'parent' }, 'parent route';
    is $client->get('/tasks/')->json, [], 'mounted modulino reachable under prefix';
    $client->stop;
};

done_testing;
