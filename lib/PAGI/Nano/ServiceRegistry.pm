package PAGI::Nano::ServiceRegistry;

use strict;
use warnings;
use Carp ();

# One instance per assembled Nano app that declares any services. Holds the
# eagerly-built, per-worker results keyed by name. Vended to builders as the
# single "$app" argument (composition, via service()) and injected onto the
# PAGI scope for request-time resolution (see PAGI::Nano::Context::service).

sub new {
    my ($class) = @_;
    return bless { built => {} }, $class;
}

# Run every declared builder once, in declaration order, storing whatever each
# returns verbatim (a plain value, an unblessed per-request maker coderef, or a
# factory-marked per-call maker; see PAGI::Nano::Context::service for how that
# is later discriminated). Called from a PAGI::Lifespan startup hook, so a
# builder that dies fails lifespan startup rather than a customer request.
sub _build_all {
    my ($self, $services) = @_;
    for my $entry (@$services) {
        my ($name, $builder) = @$entry;
        $self->{built}{$name} = $builder->($self);
    }
}

sub service {
    my ($self, $name) = @_;
    Carp::croak("no service named '$name' (services build in declaration order at startup)")
        unless exists $self->{built}{$name};
    return $self->{built}{$name};
}

1;

=encoding utf8

=head1 NAME

PAGI::Nano::ServiceRegistry - The per-app registry backing PAGI::Nano's service keyword

=head1 DESCRIPTION

One instance is created per assembled L<PAGI::Nano> app that declares any
C<service>. It is never constructed directly by application code; it is the
object passed to every service builder (as C<$app> in the C<service> examples)
and the object C<< $c->service >> resolves against at request time.

=head1 METHODS

=head2 service

    my $value = $app->service('name');

Returns an already-built service, for use inside another service's builder
(composition). Services build eagerly, in declaration order, at lifespan
startup; asking for one declared later in the same C<app { }> block (or not
declared at all) croaks, naming the service.

=head1 SEE ALSO

L<PAGI::Nano>, L<PAGI::Nano::Context>.

=head1 AUTHOR

John Napiorkowski C<< <jjnapiork@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2026, John Napiorkowski. This library is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

=cut
