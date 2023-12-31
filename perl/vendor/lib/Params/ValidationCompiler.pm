package Params::ValidationCompiler;

use strict;
use warnings;

our $VERSION = '0.22';

use Params::ValidationCompiler::Compiler;

use Exporter qw( import );

our @EXPORT_OK = qw( compile source_for validation_for );

sub validation_for {
    return Params::ValidationCompiler::Compiler->new(@_)->subref;
}

## no critic (TestingAndDebugging::ProhibitNoWarnings)
no warnings 'once';
*compile = \&validation_for;
## use critic

sub source_for {
    return Params::ValidationCompiler::Compiler->new(@_)->source_for;
}

1;

# ABSTRACT: Build an optimized subroutine parameter validator once, use it forever

__END__

=pod

=encoding UTF-8

=head1 NAME

Params::ValidationCompiler - Build an optimized subroutine parameter validator once, use it forever

=head1 VERSION

version 0.22

=head1 SYNOPSIS

    use Types::Standard qw( Int Str );
    use Params::ValidationCompiler qw( validation_for );

    {
        my $validator = validation_for(
            params => {
                foo => { type => Int },
                bar => {
                    type     => Str,
                    optional => 1,
                },
                baz => {
                    type    => Int,
                    default => 42,
                },
            },
        );

        sub foo {
            my %args = $validator->(@_);
        }
    }

    {
        my $validator = validation_for(
            params => [
                { type => Int },
                {
                    type     => Str,
                    optional => 1,
                },
            ],
        );

        sub bar {
            my ( $int, $str ) = $validator->(@_);
        }
    }

    {
        my $validator = validation_for(
            params => [
                foo => { type => Int },
                bar => {
                    type     => Str,
                    optional => 1,
                },
            ],
            named_to_list => 1,
        );

        sub baz {
            my ( $foo, $bar ) = $validator->(@_);
        }
    }

=head1 DESCRIPTION

This module creates a customized, highly efficient parameter checking
subroutine. It can handle named or positional parameters, and can return the
parameters as key/value pairs or a list of values.

In addition to type checks, it also supports parameter defaults, optional
parameters, and extra "slurpy" parameters.

=for Pod::Coverage compile

=head1 EXPORTS

This module has two options exports, C<validation_for> and C<source_for>. Both
of these subs accept the same options:

=over 4

=item * params

An arrayref or hashref containing a parameter specification.

If you pass a hashref then the generated validator sub will expect named
parameters. The C<params> value should be a hashref where the parameter names
are keys and the specs are the values.

If you pass an arrayref and C<named_to_list> is false, the validator will
expect positional params. Each element of the C<params> arrayref should be a
parameter spec.

If you pass an arrayref and C<named_to_list> is false, the validator will
expect named params, but will return a list of values. In this case the
arrayref should contain a I<list> of key/value pairs, where parameter names
are the keys and the specs are the values.

Each spec can contain either a boolean or hashref. If the spec is a boolean,
this indicates required (true) or optional (false).

The spec hashref accepts the following keys:

=over 8

=item * type

A type object. This can be a L<Moose> type (from L<Moose> or
L<MooseX::Types>), a L<Type::Tiny> type, or a L<Specio> type.

If the type has coercions, those will always be used.

=item * default

This can either be a simple (non-reference) scalar or a subroutine
reference. The sub ref will be called without any arguments (for now).

=item * optional

A boolean indicating whether or not the parameter is optional. By default,
parameters are required unless you provide a default.

=back

=item * slurpy

If this is a simple true value, then the generated subroutine accepts
additional arguments not specified in C<params>. By default, extra arguments
cause an exception.

You can also pass a type constraint here, in which case all extra arguments
must be values of the specified type.

=item * named_to_list

If this is true, the generated subroutine will expect a list of key-value
pairs or a hashref and it will return a list containing only the values.
C<params> must be a arrayref of key-value pairs in the order of which the
values should be returned.

You cannot combine C<slurpy> with C<named_to_list> as there is no way to know
how the order in which extra values should be returned.

=back

=head2 validation_for(...)

This returns a subroutine that implements the specific parameter
checking. This subroutine expects to be given the parameters to validate in
C<@_>. If all the parameters are valid, it will return the validated
parameters (with defaults as appropriate), either as a list of key-value pairs
or as a list of just values. If any of the parameters are invalid it will
throw an exception.

For validators expected named params, the generated subroutine accepts either
a list of key-value pairs or a single hashref. Otherwise the validator expects
a list of values.

For now, you must shift off the invocant yourself.

This subroutine accepts an additional parameter:

=over 4

=item * name

If this is given, then the generated subroutine will be named using
L<Sub::Util>. This is strongly recommended as it makes it possible to
distinguish different check subroutines when profiling or in stack traces.

Note that you must install L<Sub::Util> yourself separately, as it is not
required by this distribution, in order to avoid requiring a compiler.

=item * name_is_optional

If this is true, then the name is ignored when C<Sub::Util> is not
installed. If this is false, then passing a name when L<Sub::Util> cannot be
loaded causes an exception.

This is useful for CPAN modules where you want to set a name if you can, but
you do not want to add a prerequisite on L<Sub::Util>.

=back

=head2 source_for(...)

This returns a two element list. The first is a string containing the source
code for the generated sub. The second is a hashref of "environment" variables
to be used when generating the subroutine. These are the arguments that are
passed to L<Eval::Closure>.

=head1 SUPPORT

Bugs may be submitted through L<https://github.com/houseabsolute/Params-ValidationCompiler/issues>.

I am also usually active on IRC as 'autarch' on C<irc://irc.perl.org>.

=head1 DONATIONS

If you'd like to thank me for the work I've done on this module, please
consider making a "donation" to me via PayPal. I spend a lot of free time
creating free software, and would appreciate any support you'd care to offer.

Please note that B<I am not suggesting that you must do this> in order for me
to continue working on this particular software. I will continue to do so,
inasmuch as I have in the past, for as long as it interests me.

Similarly, a donation made in this way will probably not make me work on this
software much more, unless I get so many donations that I can consider working
on free software full time (let's all have a chuckle at that together).

To donate, log into PayPal and send money to autarch@urth.org, or use the
button at L<http://www.urth.org/~autarch/fs-donation.html>.

=head1 AUTHOR

Dave Rolsky <autarch@urth.org>

=head1 CONTRIBUTORS

=for stopwords Gregory Oschwald Tomasz Konojacki

=over 4

=item *

Gregory Oschwald <goschwald@maxmind.com>

=item *

Tomasz Konojacki <me@xenu.pl>

=back

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2016 by Dave Rolsky.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
