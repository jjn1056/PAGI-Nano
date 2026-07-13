package PAGI::Nano::Context;

use strict;
use warnings;
use Carp ();

# Shared behavior mixed into every Nano context (HTTP, WebSocket, SSE) alongside
# the stock PAGI context class for that scope type. It only needs $self->{scope},
# which all of them carry. uri_for lives here (not in PAGI-Tools) because it
# resolves against the flat name registry PAGI::Nano injects on the scope — a
# Nano concept the base toolkit knows nothing about.

# Build a URL for a named route. Resolves against the flat name->path registry
# PAGI::Nano injects on the scope, so any name in the app (including across
# mounts, in either direction) is reachable.
sub uri_for {
    my ($self, $name, $path_params, $query_params) = @_;

    my $routes = $self->{scope}{'pagi.nano.routes'};
    Carp::croak('uri_for: no named-route registry on the scope '
        . '(is this a PAGI::Nano app, and is the route named?)')
        unless $routes;
    my $path = $routes->{$name};
    Carp::croak("uri_for: no route named '$name'") unless defined $path;

    $path_params  ||= {};
    $query_params ||= {};

    for my $key (keys %$path_params) {
        my $val = $path_params->{$key};
        $val = '' unless defined $val;
        $path =~ s/\{\Q$key\E(?::[^}]*)?\}/$val/g
            or $path =~ s/:\Q$key\E(?!\w)/$val/g
            or $path =~ s/\*\Q$key\E(?!\w)/$val/g;
    }

    if (%$query_params) {
        my @pairs;
        for my $k (sort keys %$query_params) {
            push @pairs, _uri_escape($k) . '=' . _uri_escape($query_params->{$k});
        }
        $path .= '?' . join('&', @pairs);
    }

    return $path;
}

# Resolve a declared service by name. Delegates to the registry PAGI::Nano
# injects on the scope (the same mechanism uri_for uses for named routes),
# which applies the scope-discrimination rule: an app-scoped value is returned
# as-is, a per-request maker is invoked and memoized for this request/
# connection, and a factory-marked maker is invoked fresh on every call.
sub service {
    my ($self, $name) = @_;

    my $registry = $self->{scope}{'pagi.nano.services'};
    Carp::croak("service: no service registry on the scope "
        . "(is this a PAGI::Nano app, and was '$name' declared?)")
        unless $registry;

    return $registry->_resolve($name, $self);
}

sub _uri_escape {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

1;

=encoding utf8

=head1 NAME

PAGI::Nano::Context - Shared behavior for the contexts PAGI::Nano vends

=head1 DESCRIPTION

A mixin inherited by L<PAGI::Nano::Context::HTTP>,
L<PAGI::Nano::Context::WebSocket>, and L<PAGI::Nano::Context::SSE> alongside the
stock PAGI context class for each scope type. It provides L</uri_for>, which is
available to handlers of every protocol.

=head1 METHODS

=head2 uri_for

    my $url = $c->uri_for($name);
    my $url = $c->uri_for($name, \%path_params);
    my $url = $c->uri_for($name, \%path_params, \%query_params);

Builds the URL for a route named with L<PAGI::Nano/name>. Path placeholders
(C<:id>, C<{id}>, C<{id:regex}>, C<*splat>) are filled from C<%path_params>, and
C<%query_params> (if any) is appended as a percent-encoded query string.
Resolution is against the flat name registry PAGI::Nano injects on the scope, so
names defined anywhere in the app — including across a C<mount>, in either
direction — are reachable, with mount prefixes applied. Dies if the name is
unknown.

=head1 AUTHOR

John Napiorkowski C<< <jjnapiork@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2026, John Napiorkowski. This library is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

=cut
