package Params::ValidationCompiler::Compiler;

use strict;
use warnings;

our $VERSION = '0.22';

use Carp qw( croak );
use Eval::Closure qw( eval_closure );
use List::Util 1.29 qw( pairkeys pairvalues );
use Params::ValidationCompiler::Exceptions;
use Scalar::Util qw( blessed looks_like_number reftype );
use overload ();
use B qw( perlstring );

our @CARP_NOT = ( 'Params::ValidationCompiler', __PACKAGE__ );

BEGIN {
    ## no critic (Variables::RequireInitializationForLocalVars)
    local $@;
    my $has_sub_util = eval {
        require Sub::Util;
        Sub::Util->VERSION(1.40);
        Sub::Util->import('set_subname');
        1;
    };

    sub HAS_SUB_UTIL () {$has_sub_util}

    unless ($has_sub_util) {
        *set_subname = sub {
            croak
                'Cannot name a generated validation subroutine. Please install Sub::Util.';
        };
    }
}

my %known
    = map { $_ => 1 } qw( name name_is_optional params slurpy named_to_list );

# I'd rather use Moo here but I want to make things relatively high on the
# CPAN river like DateTime use this distro, so reducing deps is important.
sub new {
    my $class = shift;
    my %p     = @_;

    unless ( exists $p{params} ) {
        croak
            q{You must provide a "params" parameter when creating a parameter validator};
    }
    if ( ref $p{params} eq 'HASH' ) {
        croak q{The "params" hashref must contain at least one key-value pair}
            unless %{ $p{params} };

        croak
            q{"named_to_list" must be used with arrayref params containing key-value pairs}
            if $p{named_to_list};

        $class->_validate_param_spec($_) for values %{ $p{params} };
    }
    elsif ( ref $p{params} eq 'ARRAY' ) {
        croak q{The "params" arrayref must contain at least one element}
            unless @{ $p{params} };

        my @specs
            = $p{named_to_list}
            ? pairvalues @{ $p{params} }
            : @{ $p{params} };

        $class->_validate_param_spec($_) for @specs;
    }
    else {
        my $type
            = !defined $p{params} ? 'an undef'
            : ref $p{params} ? q{a } . ( lc ref $p{params} ) . q{ref}
            :                  'a scalar';

        croak
            qq{The "params" parameter when creating a parameter validator must be a hashref or arrayref, you passed $type};
    }

    if ( $p{named_to_list} && $p{slurpy} ) {
        croak q{You cannot use "named_to_list" and "slurpy" together};
    }

    if ( exists $p{name} && ( !defined $p{name} || ref $p{name} ) ) {
        my $type
            = !defined $p{name}
            ? 'an undef'
            : q{a } . ( lc ref $p{name} ) . q{ref};

        croak
            qq{The "name" parameter when creating a parameter validator must be a scalar, you passed $type};
    }

    my @unknown = sort grep { !$known{$_} } keys %p;
    if (@unknown) {
        croak
            "You passed unknown parameters when creating a parameter validator: [@unknown]";
    }

    my $self = bless \%p, $class;

    $self->{_source} = [];
    $self->{_env}    = {};

    return $self;
}

{
    my %known_keys = (
        default  => 1,
        optional => 1,
        type     => 1,
    );

    sub _validate_param_spec {
        shift;
        my $spec = shift;

        my $ref = ref $spec;
        return unless $ref;

        croak
            "Specifications must be a scalar or hashref, but received a $ref"
            unless $ref eq 'HASH';

        my @unknown = sort grep { !$known_keys{$_} } keys %{$spec};
        if (@unknown) {
            croak "Specification contains unknown keys: [@unknown]";
        }
    }
}

sub name      { $_[0]->{name} }
sub _has_name { exists $_[0]->{name} }

sub _name_is_optional { $_[0]->{name_is_optional} }

# I have no idea why critic thinks _caller isn't used.

## no critic (Subroutines::ProhibitUnusedPrivateSubroutines)
sub _caller { $_[0]->{caller} }
## use critic
sub _has_caller { exists $_[0]->{caller} }

sub params { $_[0]->{params} }

sub slurpy { $_[0]->{slurpy} }

sub _source { $_[0]->{_source} }

sub _env { $_[0]->{_env} }

sub named_to_list { $_[0]->{named_to_list} }

sub _any_type_has_coercion {
    my $self = shift;

    return $self->{_has_coercion} if exists $self->{_has_coercion};

    for my $type ( $self->_types ) {

        # Specio
        if ( $type->can('has_coercions') && $type->has_coercions ) {
            return $self->{_has_coercion} = 1;
        }

        # Moose and Type::Tiny
        elsif ( $type->can('has_coercion') && $type->has_coercion ) {
            return $self->{_has_coercion} = 1;
        }
    }

    return $self->{_has_coercion} = 0;
}

sub _types {
    my $self = shift;

    if ( ref $self->params eq 'HASH' ) {
        return map { $_->{type} || () }
            grep { ref $_ } values %{ $self->params };
    }
    elsif ( ref $self->params eq 'ARRAY' ) {
        if ( $self->named_to_list ) {
            my %p = @{ $self->params };
            return map { $_->{type} || () } grep { ref $_ } values %p;
        }
        else {
            return
                map { $_->{type} || () } grep { ref $_ } @{ $self->params };
        }
    }
}

sub subref {
    my $self = shift;

    $self->_compile;
    my $sub = eval_closure(
        source => 'sub { ' . ( join "\n", @{ $self->_source } ) . ' };',
        environment => $self->_env,
    );

    if ( $self->_has_name ) {
        my $caller = $self->_has_caller ? $self->_caller : caller(1);
        my $name = join '::', $caller, $self->name;

        return $sub if $self->_name_is_optional && !HAS_SUB_UTIL;
        set_subname( $name, $sub );
    }

    return $sub;
}

sub source {
    my $self = shift;

    $self->_compile;
    return (
        ( join "\n", @{ $self->_source } ),
        $self->_env,
    );
}

sub _compile {
    my $self = shift;

    if ( ref $self->params eq 'HASH' ) {
        $self->_compile_named_args_check;
    }
    elsif ( ref $self->params eq 'ARRAY' ) {
        if ( $self->named_to_list ) {
            $self->_compile_named_args_list_check;
        }
        else {
            $self->_compile_positional_args_check;
        }
    }
}

sub _compile_named_args_check {
    my $self = shift;

    $self->_compile_named_args_check_body( $self->params );
    push @{ $self->_source }, 'return %args;';

    return;
}

sub _compile_named_args_list_check {
    my $self = shift;

    $self->_compile_named_args_check_body( { @{ $self->params } } );

    my @keys = map { perlstring($_) } pairkeys @{ $self->params };

    # If we don't handle the one-key case specially we end up getting a
    # warning like "Scalar value @args{"bar"} better written as $args{"bar"}
    # at ..."
    if ( @keys == 1 ) {
        push @{ $self->_source }, "return \$args{$keys[0]};";
    }
    else {
        my $keys_str = join q{, }, @keys;
        push @{ $self->_source }, "return \@args{$keys_str};";
    }

    return;
}

sub _compile_named_args_check_body {
    my $self   = shift;
    my $params = shift;

    push @{ $self->_source }, $self->_set_named_args_hash;

    for my $name ( sort keys %{$params} ) {
        my $spec = $params->{$name};
        $spec = { optional => !$spec } unless ref $spec;

        my $qname  = perlstring($name);
        my $access = "\$args{$qname}";

        # We check exists $spec->{optional} so as not to blow up on a
        # restricted hash.
        $self->_add_check_for_required_named_param( $access, $name )
            unless ( exists $spec->{optional} && $spec->{optional} )
            || exists $spec->{default};

        $self->_add_named_default_assignment(
            $access,
            $name,
            $spec->{default}
        ) if exists $spec->{default};

        # Same issue with restricted hashes here.
        $self->_add_type_check( $access, $name, $spec )
            if exists $spec->{type} && $spec->{type};
    }

    if ( $self->slurpy ) {
        $self->_add_check_for_extra_hash_param_types( $self->slurpy, $params )
            if ref $self->slurpy;
    }
    else {
        $self->_add_check_for_extra_hash_params($params);
    }

    return;
}

sub _set_named_args_hash {
    my $self = shift;

    push @{ $self->_source }, <<'EOF';
my %args;
if ( @_ % 2 == 0 ) {
    %args = @_;
}
elsif ( @_ == 1 ) {
    if ( ref $_[0] ) {
        if ( Scalar::Util::blessed( $_[0] ) ) {
            if ( overload::Overloaded( $_[0] )
                && defined overload::Method( $_[0], '%{}' ) ) {

                %args = %{ $_[0] };
            }
            else {
                Params::ValidationCompiler::Exception::BadArguments->throw(
                    message =>
                        'Expected a hash or hash reference but got a single object argument'
                );
            }
        }
        elsif ( ref $_[0] eq 'HASH' ) {
            %args = %{ $_[0] };
        }
        else {
            Params::ValidationCompiler::Exception::BadArguments->throw(
                message =>
                    'Expected a hash or hash reference but got a single '
                    . ( ref $_[0] )
                    . ' reference argument',
            );
        }
    }
    else {
        Params::ValidationCompiler::Exception::BadArguments->throw(
            message =>
                'Expected a hash or hash reference but got a single non-reference argument',
        );
    }
}
else {
    Params::ValidationCompiler::Exception::BadArguments->throw(
        message =>
            'Expected a hash or hash reference but got an odd number of arguments',
    );
}
EOF

    return;
}

sub _add_check_for_required_named_param {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;

    my $qname = perlstring($name);
    push @{ $self->_source },
        sprintf( <<'EOF', $access, ($qname) x 2 );
exists %s
    or Params::ValidationCompiler::Exception::Named::Required->throw(
    message   => %s . ' is a required parameter',
    parameter => %s,
    );
EOF

    return;
}

sub _add_check_for_extra_hash_param_types {
    my $self   = shift;
    my $type   = shift;
    my $params = shift;

    $self->_env->{'%known'}
        = { map { $_ => 1 } keys %{$params} };

    # We need to set the name argument to something that won't conflict with
    # names someone would actually use for a parameter.
    my $check = join q{}, $self->_type_check(
        '$args{$key}',
        '__PCC extra parameters__',
        $type,
    );
    push @{ $self->_source }, sprintf( <<'EOF', $check );
for my $key ( grep { !$known{$_} } keys %%args ) {
    %s;
}
EOF

    return;
}

sub _add_check_for_extra_hash_params {
    my $self   = shift;
    my $params = shift;

    $self->_env->{'%known'}
        = { map { $_ => 1 } keys %{$params} };
    push @{ $self->_source }, <<'EOF';
my @extra = grep { ! $known{$_} } keys %args;
if ( @extra ) {
    my $u = join ', ', sort @extra;
    Params::ValidationCompiler::Exception::Named::Extra->throw(
        message    => "found extra parameters: [$u]",
        parameters => \@extra,
    );
}
EOF

    return;
}

sub _compile_positional_args_check {
    my $self = shift;

    my @specs = $self->_munge_and_check_positional_params;

    my $first_optional_idx = -1;
    for my $i ( 0 .. $#specs ) {
        next unless $specs[$i]{optional} || exists $specs[$i]{default};
        $first_optional_idx = $i;
        last;
    }

    # If optional params start anywhere after the first parameter spec then we
    # must require at least one param. If there are no optional params then
    # they're all required.
    $self->_add_check_for_required_positional_params(
        $first_optional_idx == -1
        ? ( scalar @specs )
        : $first_optional_idx
    ) if $first_optional_idx != 0;

    $self->_add_check_for_extra_positional_params( scalar @specs )
        unless $self->slurpy;

    my $access_var = '$_';
    my $return_var = '@_';
    if ( $self->_any_type_has_coercion ) {
        push @{ $self->_source }, 'my @copy = @_;';
        $access_var = '$copy';
        $return_var = '@copy';
    }

    for my $i ( 0 .. $#specs ) {
        my $spec = $specs[$i];

        my $name = "Parameter $i";
        my $access = sprintf( '%s[%i]', $access_var, $i );

        $self->_add_positional_default_assignment(
            $i,
            $access,
            $name,
            $spec->{default}
        ) if exists $spec->{default};

        $self->_add_type_check( $access, $name, $spec )
            if $spec->{type};
    }

    if ( ref $self->slurpy ) {
        $self->_add_check_for_extra_positional_param_types(
            scalar @specs,
            $self->slurpy,
        );
    }

    push @{ $self->_source }, sprintf( 'return %s;', $return_var );

    return;
}

sub _munge_and_check_positional_params {
    my $self = shift;

    my @specs;
    my $in_optional = 0;

    for my $spec ( @{ $self->params } ) {
        $spec = ref $spec ? $spec : { optional => !$spec };
        if ( $spec->{optional} ) {
            $in_optional = 1;
        }
        elsif ($in_optional) {
            croak
                'Parameter list contains an optional parameter followed by a required parameter.';
        }

        push @specs, $spec;
    }

    return @specs;
}

sub _add_check_for_required_positional_params {
    my $self = shift;
    my $min  = shift;

    push @{ $self->_source }, sprintf( <<'EOF', ($min) x 3 );
if ( @_ < %d ) {
    my $got = scalar @_;
    my $got_n = @_ == 1 ? 'parameter' : 'parameters';
    Params::ValidationCompiler::Exception::Positional::Required->throw(
        message => "got $got $got_n but expected at least %d",
        minimum => %d,
        got     => scalar @_,
    );
}
EOF

    return;
}

sub _add_check_for_extra_positional_param_types {
    my $self = shift;
    my $max  = shift;
    my $type = shift;

    # We need to set the name argument to something that won't conflict with
    # names someone would actually use for a parameter.
    my $check = join q{}, $self->_type_check(
        '$_[$i]',
        '__PCC extra parameters__',
        $type,
    );
    push @{ $self->_source }, sprintf( <<'EOF', $max, $max, $check );
if ( @_ > %d ) {
    for my $i ( %d .. $#_ ) {
        %s;
    }
}
EOF

    return;
}

sub _add_check_for_extra_positional_params {
    my $self = shift;
    my $max  = shift;

    push @{ $self->_source }, sprintf( <<'EOF', ($max) x 3 );
if ( @_ > %d ) {
    my $extra = @_ - %d;
    my $extra_n = $extra == 1 ? 'parameter' : 'parameters';
    Params::ValidationCompiler::Exception::Positional::Extra->throw(
        message => "got $extra extra $extra_n",
        maximum => %d,
        got     => scalar @_,
    );
}
EOF

    return;
}

sub _add_positional_default_assignment {
    my $self     = shift;
    my $position = shift;
    my $access   = shift;
    my $name     = shift;
    my $default  = shift;

    push @{ $self->_source }, "if ( \$#_ < $position ) {";
    $self->_add_shared_default_assignment( $access, $name, $default );
    push @{ $self->_source }, '}';

    return;
}

sub _add_named_default_assignment {
    my $self    = shift;
    my $access  = shift;
    my $name    = shift;
    my $default = shift;

    my $qname = perlstring($name);
    push @{ $self->_source }, "unless ( exists \$args{$qname} ) {";
    $self->_add_shared_default_assignment( $access, $name, $default );
    push @{ $self->_source }, '}';

    return;
}

sub _add_shared_default_assignment {
    my $self    = shift;
    my $access  = shift;
    my $name    = shift;
    my $default = shift;

    my $qname = perlstring($name);

    croak 'Default must be either a plain scalar or a subroutine reference'
        if ref $default && reftype($default) ne 'CODE';

    if ( ref $default ) {
        push @{ $self->_source }, "$access = \$defaults{$qname}->();";
        $self->_env->{'%defaults'}{$name} = $default;
    }
    else {
        if ( defined $default ) {
            if ( looks_like_number($default) ) {
                push @{ $self->_source }, "$access = $default;";
            }
            else {
                push @{ $self->_source },
                    "$access = " . perlstring($default) . ';';
            }
        }
        else {
            push @{ $self->_source }, "$access = undef;";
        }
    }

    return;
}

sub _add_type_check {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;
    my $spec   = shift;

    my $type = $spec->{type};
    croak "Passed a type that is not an object for $name: $type"
        unless blessed $type;

    push @{ $self->_source }, sprintf( 'if ( exists %s ) {', $access )
        if $spec->{optional};

    push @{ $self->_source },
        $self->_type_check( $access, $name, $spec->{type} );

    push @{ $self->_source }, '}'
        if $spec->{optional};

    return;
}

sub _type_check {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;
    my $type   = shift;

    # Specio
    return $type->can('can_inline_coercion_and_check')
        ? $self->_add_specio_check( $access, $name, $type )

        # Type::Tiny
        : $type->can('inline_assert')
        ? $self->_add_type_tiny_check( $access, $name, $type )

        # Moose
        : $type->can('can_be_inlined')
        ? $self->_add_moose_check( $access, $name, $type )
        : croak 'Unknown type object ' . ref $type;
}

# From reading through the Type::Tiny source, I can't see any cases where a
# Type::Tiny type or coercion needs to provide any environment variables to
# compile with.
sub _add_type_tiny_check {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;
    my $type   = shift;

    my $qname = perlstring($name);

    my @source;
    if ( $type->has_coercion ) {
        my $coercion = $type->coercion;
        if ( $coercion->can_be_inlined ) {
            push @source,
                "$access = " . $coercion->inline_coercion($access) . ';';
        }
        else {
            $self->_env->{'%tt_coercions'}{$name}
                = $coercion->compiled_coercion;
            push @source,
                sprintf(
                '%s = $tt_coercions{%s}->( %s );',
                $access, $qname, $access,
                );
        }
    }

    if ( $type->can_be_inlined ) {
        push @source,
            $type->inline_assert($access);
    }
    else {
        push @source,
            sprintf(
            '$types{%s}->assert_valid( %s );',
            $qname, $access,
            );
        $self->_env->{'%types'}{$name} = $type;
    }

    return @source;
}

sub _add_specio_check {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;
    my $type   = shift;

    my $qname = perlstring($name);

    my @source;

    if ( $type->can_inline_coercion_and_check ) {
        if ( $type->has_coercions ) {
            my ( $source, $env ) = $type->inline_coercion_and_check($access);
            push @source, sprintf( '%s = %s;', $access, $source );
            $self->_add_to_environment(
                sprintf(
                    'The inline_coercion_and_check for %s ',
                    $type->_description
                ),
                $env,
            );
        }
        else {
            my ( $source, $env ) = $type->inline_assert($access);
            push @source, $source . ';';
            $self->_add_to_environment(
                sprintf(
                    'The inline_assert for %s ',
                    $type->_description
                ),
                $env,
            );
        }
    }
    else {
        my @coercions = $type->coercions;
        $self->_env->{'%specio_coercions'}{$name} = \@coercions;
        for my $i ( 0 .. $#coercions ) {
            my $c = $coercions[$i];
            if ( $c->can_be_inlined ) {
                push @source,
                    sprintf(
                    '%s = %s if %s;',
                    $access,
                    $c->inline_coercion($access),
                    $c->from->inline_check($access)
                    );
                $self->_add_to_environment(
                    sprintf(
                        'The inline_coercion for %s ',
                        $c->_description
                    ),

                    # This should really be public in Specio
                    $c->_inline_environment,
                );
            }
            else {
                push @source,
                    sprintf(
                    '%s = $specio_coercions{%s}[%s]->coerce(%s) if $specio_coercions{%s}[%s]->from->value_is_valid(%s);',
                    $access,
                    $qname,
                    $i,
                    $access,
                    $qname,
                    $i,
                    $access
                    );
            }
        }

        push @source,
            sprintf(
            '$types{%s}->validate_or_die(%s);',
            $qname, $access,
            );

        $self->_env->{'%types'}{$name} = $type;
    }

    return @source;
}

sub _add_moose_check {
    my $self   = shift;
    my $access = shift;
    my $name   = shift;
    my $type   = shift;

    my $qname = perlstring($name);

    my @source;

    if ( $type->has_coercion ) {
        $self->_env->{'%moose_coercions'}{$name} = $type->coercion;
        push @source,
            sprintf(
            '%s = $moose_coercions{%s}->coerce( %s );',
            $access, $qname, $access,
            );
    }

    $self->_env->{'%types'}{$name} = $type;

    my $code = <<'EOF';
if ( !%s ) {
    my $type  = $types{%s};
    my $param = %s;
    my $value = %s;
    my $msg   = $param . q{ failed with: } . $type->get_message($value);
    die
        Params::ValidationCompiler::Exception::ValidationFailedForMooseTypeConstraint
        ->new(
        message   => $msg,
        parameter => $param,
        value     => $value,
        type      => $type,
        );
}
EOF

    my $check
        = $type->can_be_inlined
        ? $type->_inline_check($access)
        : sprintf( '$types{%s}->check( %s )', $qname, $access );

    push @source, sprintf(
        $code,
        $check,
        $qname,
        $qname,
        $access,
    );

    if ( $type->can_be_inlined ) {
        $self->_add_to_environment(
            sprintf( 'The %s type', $type->name ),
            $type->_inline_environment,
        );
    }

    return @source;
}

sub _add_to_environment {
    my $self    = shift;
    my $what    = shift;
    my $new_env = shift;

    my $env = $self->_env;
    for my $key ( keys %{$new_env} ) {
        if ( exists $env->{$key} ) {
            croak sprintf(
                      '%s has an inline environment variable named %s'
                    . ' that conflicts with a variable already in the environment',
                $what, $key
            );
        }
        $self->_env->{$key} = $new_env->{$key};
    }
}

1;

# ABSTRACT: Object that implements the check subroutine compilation

__END__

=pod

=encoding UTF-8

=head1 NAME

Params::ValidationCompiler::Compiler - Object that implements the check subroutine compilation

=head1 VERSION

version 0.22

=for Pod::Coverage .*

=head1 SUPPORT

Bugs may be submitted through L<https://github.com/houseabsolute/Params-ValidationCompiler/issues>.

I am also usually active on IRC as 'autarch' on C<irc://irc.perl.org>.

=head1 AUTHOR

Dave Rolsky <autarch@urth.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2016 by Dave Rolsky.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
