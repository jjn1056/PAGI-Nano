use v5.40;
use experimental 'signatures';
use FindBin;
use PAGI::Nano;

# Ports PAGI-Tools' app-01-file to PAGI::Nano.
# Static file serving (index resolution, MIME types, ETag/304, range requests,
# path-traversal protection) all come from PAGI::App::File, which `static` mounts
# under a prefix.
#
# Note: the underlying router does not support mounting at the bare root '/', so
# static assets are served under a prefix here (the documented Nano idiom). For a
# pure root file server, use PAGI::App::File->new(root => ...)->to_app directly as
# the whole app.
#
#     pagi-server app.pl
#     curl http://127.0.0.1:5000/assets/

my $dir = "$FindBin::Bin/public/";

my $app = app {
    get '/' => sub ($c) {
        $c->html('<a href="/assets/">browse static assets</a>');
    };
    static '/assets' => $dir;
};

$app;
