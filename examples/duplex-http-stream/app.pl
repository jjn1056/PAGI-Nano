use v5.40;
use experimental 'signatures';
use Future;
use Future::AsyncAwait;
use Future::IO;
use PAGI::Nano;

# Full-duplex over a single HTTP request: read the streaming request body while
# concurrently streaming the response. This is the HTTP-streaming analog of
# examples/bidirectional-websocket — two branches raced with wait_any, one
# echoing client input, one pushing server ticks unsolicited.
#
# Caveats (this is why WebSocket exists): no message framing (it's a byte stream
# both ways), browsers can't do full-duplex on a single fetch, and HTTP/1.1
# proxies may buffer the request before forwarding. It is a fine fit for
# non-browser / service-to-service / HTTP-2 clients.
#
#     pagi-server app.pl
#     # plain curl: the connection drives the stream, so ticks keep coming until
#     # you stop reading (not tied to the request body):
#     curl -N -XPOST --max-time 4 http://127.0.0.1:5000/duplex
#     # full duplex (stream the request body while reading the response):
#     perl probe.pl 5000

my $app = app {
    post '/duplex' => async sub ($c) {
        my $in = $c->req->body_stream;
        $c->response->stream(async sub ($w) {
            # Echo request-body chunks as they arrive, concurrently. This branch
            # ends when the client finishes its body — but that must NOT end the
            # stream: the client can stop sending and keep receiving. So it runs
            # alongside the ticker, it does not drive termination.
            my $echoer = (async sub {
                while (defined(my $chunk = await $in->next_chunk)) {
                    next unless length $chunk;
                    await $w->write("echo: $chunk\n");
                }
            })->();

            # The stream lives as long as the client stays connected, pushing a
            # tick a second. (In-process test clients report no live connection,
            # so this loop is skipped there; the real full-duplex behavior is
            # demonstrated by probe.pl against pagi-server.)
            my $n = 0;
            while (!$c->is_disconnected) {
                await $w->write('tick ' . (++$n) . "\n");
                await Future::IO->sleep(1);
            }

            $echoer->cancel unless $echoer->is_ready;
            await $w->close;
        });
    };
};

$app;
