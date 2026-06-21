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
#     # then drive it full-duplex with a client that streams the request body
#     # while reading the response (see the raw-socket probe in the project tests).

my $app = app {
    post '/duplex' => async sub ($c) {
        my $in = $c->req->body_stream;
        $c->response->stream(async sub ($w) {
            # incoming: echo each request-body chunk back as it arrives
            my $incoming = async sub {
                while (defined(my $chunk = await $in->next_chunk)) {
                    next unless length $chunk;     # skip the empty final chunk
                    await $w->write("echo: $chunk\n");
                }
            };
            # outgoing: push a tick every second, unsolicited
            my $outgoing = async sub {
                my $n = 0;
                while (1) {
                    await $w->write('tick ' . (++$n) . "\n");
                    await Future::IO->sleep(1);
                }
            };
            # finish when the client closes its request body (incoming ends)
            await Future->wait_any($incoming->(), $outgoing->());
            await $w->close;
        });
    };
};

$app;
