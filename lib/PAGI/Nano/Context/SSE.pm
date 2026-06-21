package PAGI::Nano::Context::SSE;

use strict;
use warnings;
use parent -norequire, 'PAGI::Context::SSE', 'PAGI::Nano::Context';
use PAGI::Context;        # base declares @ISA but does not load it
use PAGI::Context::SSE;
use PAGI::Nano::Context;  # the shared mixin (uri_for)

# The SSE context Nano vends: a genuine PAGI::Context::SSE (so $c->sse and the
# rest of the SSE API work) plus the shared Nano behavior, notably $c->uri_for
# for building links from SSE handlers. Blessed directly so the base factory's
# scope-type resolution does not down-cast us.

sub new {
    my ($class, $scope, $receive, $send) = @_;
    return bless {
        scope   => $scope,
        receive => $receive,
        send    => $send,
    }, $class;
}

1;

=encoding utf8

=head1 NAME

PAGI::Nano::Context::SSE - The SSE context vended by PAGI::Nano

=head1 DESCRIPTION

A subclass of L<PAGI::Context::SSE> (so C<< $c->sse >> and the full SSE API are
available) that also mixes in L<PAGI::Nano::Context>, giving SSE handlers
C<< $c->uri_for >> for link generation.

=head1 SEE ALSO

L<PAGI::Nano>, L<PAGI::Nano::Context>, L<PAGI::Context::SSE>.

=head1 AUTHOR

John Napiorkowski C<< <jjnapiork@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2026, John Napiorkowski. This library is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

=cut
