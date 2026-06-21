use v5.40;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Test::Client;
use PAGI::Nano;

# WebSocket and SSE handlers are imperative ($c->websocket / $c->sse, return
# nothing) and are not coerced. Streaming responses flow through the response
# writer with nothing buffered.

my $app = app {
    websocket '/echo' => async sub ($c) {
        my $ws = $c->websocket;
        await $ws->accept;
        await $ws->each_json(async sub ($msg) {
            await $ws->send_json({ echo => $msg });
        });
    };

    sse '/events' => async sub ($c) {
        my $s = $c->sse;
        for my $i (1 .. 3) { await $s->send("tick $i") }
        await $s->close;
    };

    post '/upper' => async sub ($c) {
        my $in = $c->req->body_stream;
        $c->response->stream(async sub ($w) {
            while (defined(my $chunk = await $in->next_chunk)) {
                await $w->write(uc $chunk);
            }
            await $w->close;
        });
    };
};

my $client = PAGI::Test::Client->new(app => $app);

subtest 'websocket echoes json messages' => sub {
    $client->websocket('/echo', sub ($ws) {
        $ws->send_json({ hi => 'there' });
        is $ws->receive_json, { echo => { hi => 'there' } }, 'echoed back';
    });
};

subtest 'sse streams a series of events' => sub {
    $client->sse('/events', sub ($sse) {
        is $sse->receive_event->{data}, 'tick 1', 'first tick';
        is $sse->receive_event->{data}, 'tick 2', 'second tick';
        is $sse->receive_event->{data}, 'tick 3', 'third tick';
    });
};

subtest 'streaming request body to streaming response, uppercased' => sub {
    my $res = $client->post('/upper', body => 'hello world');
    is $res->status, 200, '200';
    is $res->content, 'HELLO WORLD', 'body streamed and uppercased';
};

done_testing;
