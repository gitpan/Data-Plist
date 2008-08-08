=head1 NAME

Data::Plist - object representing a property list

=head1 SYNOPSIS

 # Create a new plist containing $data
 my $plist = Data::Plist->new($data);

 # Get nested arrays containing the perl data structure's
 # information
 my $ret = $plist->raw_data;

 # Get perl data structure
 $ret = $plist->data;

 # Get an Objective C object
 $ret = $plist->object;


=head1 DESCRIPTION

Plists are intermediate structures from which nested array
structures of the format specified in L</SERIALIZED DATA>,
perl data structures and Objective C data structures can be
obtained.

=cut

=head1 SERIALIZED DATA

Perl data structures that have been serialized become
nested array structures containing their data and their
data type. Example:

[ array => [ string => "kitten" ], [ integer => 42], [ real => 3.14159 ] ]

Array references are passed around when dealing with
serialized data.

=head1 KEYED ARCHIVES

Apple uses binary property lists as a serialization format from
Objective C, in a format C<NSKeyedArchiver>.  L<Data::Plist> has the
capability to recognize property lists which were generated using
C<NSKeyedArchiver>, and to construct perl objects based on the
information in the property list.  Objects thus created are blessed
under the C<Data::Plist::Foundation> namespace.  Thus, the root
ancestor of all Objective C objects thus imported is
L<Data::Plist::Foundation::NSObject>.

=cut

package Data::Plist;

use strict;
use warnings;

use DateTime;
use UNIVERSAL::require;

use vars qw/$VERSION/;
$VERSION = "0.1";

=head1 METHODS

=head2 new

Creates a new Data::Plist object.  Generally, you will not need to
call this directly, as Plists are generally created by
L<Data::Plist::Reader> classes, and are not needed in serialization
when using L<Data::Plist::Writer> classes.

=cut

sub new {
    my $class = shift;
    return bless { data => undef, @_ } => $class;
}

=head2 collapse $data

Takes an array of serialized data C<$data>. Recursively
returns the actual data, without the datatype labels.

=cut

sub collapse {
    my $self = shift;
    my ($data) = @_;

    unless ( ref $data eq "ARRAY" ) {
        warn "Got $data?";
        return "???";
    }

    if ( $data->[0] eq "array" ) {
        return [ map $self->collapse($_), @{ $data->[1] } ];
    } elsif ( $data->[0] eq "dict" ) {
        my %dict = %{ $data->[1] };
        $dict{$_} = $self->collapse( $dict{$_} ) for keys %dict;
        return \%dict;
    } elsif ( $data->[0] eq "string" ) {
        return $data->[1] eq '$null' ? undef : $data->[1];
    } elsif ( $data->[0] eq "date" ) {
        return DateTime->from_epoch( epoch => $data->[1] + 978307200 );
    } elsif ( $data->[0] eq "UID" and ref $data->[1] ) {
        return $self->collapse( $data->[1] );
    } else {
        return $data->[1];
    }

}

=head2 raw_data

Returns the plist as a set of nested arrays of the format specified in
L</SERIALIZED DATA>.

=cut

sub raw_data {
    my $self = shift;
    return $self->{data};
}

=head2 data

Returns the plist as its corresponding perl data structure.

=cut

sub data {
    my $self = shift;
    return $self->collapse( $self->raw_data );
}

=head2 is_archive

Checks if the plist is actually an archived Objective C generated by
C<NSKeyedArchiver>.  Returns true if it is.  See L</KEYED ARCHIVES>.

=cut

sub is_archive {
    my $self = shift;
    my $data = $self->raw_data;
    return unless $data->[0] eq "dict";

    return unless exists $data->[1]{'$archiver'};
    return unless $data->[1]{'$archiver'}[0] eq "string";
    return unless $data->[1]{'$archiver'}[1] eq "NSKeyedArchiver";

    return unless exists $data->[1]{'$objects'};
    return unless $data->[1]{'$objects'}[0] eq "array";

    return unless exists $data->[1]{'$top'};

    return unless exists $data->[1]{'$version'};
    return unless $data->[1]{'$version'}[0] eq "integer";
    return unless $data->[1]{'$version'}[1] eq "100000";

    return 1;
}

=head2 unref

Recursively strips references from the plist.

=cut

sub unref {
    my $self = shift;
    my $p    = shift;
    if ( $p->[0] eq "UID" ) {
        return [
            "UID",
            $self->unref( $self->raw_data->[1]{'$objects'}[1][ $p->[1] ] )
        ];
    } elsif ( $p->[0] eq "array" ) {
        return [ "array", [ map { $self->unref($_) } @{ $p->[1] } ] ];
    } elsif ( $p->[0] eq "dict" ) {
        my %dict = %{ $p->[1] };
        $dict{$_} = $self->unref( $dict{$_} ) for keys %dict;
        return [ "dict", \%dict ];
    } elsif ( $p->[0] eq "data"
        and ref $p->[1]
        and $p->[1]->isa("Data::Plist") )
    {
        return $p->[1]->_raw_object;
    } else {
        return $p;
    }
}

=head2 reify $data

Takes serialized data (see L</SERIALIZED DATA>) C<$data>
and checks if it's a keyed archive (see L</SERIALIZED
DATA>). If the data is a keyed archive, it blesses it into
the appropriate perl class.

=cut

sub reify {
    my $self = shift;
    my ( $data ) = @_;

    return $data unless ref $data;
    if ( ref $data eq "HASH" ) {
        my $hash  = { %{$data} };
        my $class = delete $hash->{'$class'};
        $hash->{$_} = $self->reify( $hash->{$_} ) for keys %{$hash};
        if (    $class
            and ref $class
            and ref $class eq "HASH"
            and $class->{'$classname'} )
        {
            my $classname = "Data::Plist::Foundation::" . $class->{'$classname'};
            if ( not $classname->require ) {
                warn "Can't require $classname: $@\n";
            } elsif ( not $classname->isa( "Data::Plist::Foundation::NSObject" ) ) {
                warn "$classname isn't a Data::Plist::Foundation::NSObject\n";
            } else {
                bless( $hash, $classname );
                $hash = $hash->replacement;
            }
        }
        return $hash;
    } elsif ( ref $data eq "ARRAY" ) {
        return [ map $self->reify( $_ ), @{$data} ];
    } else {
        return $data;
    }
}

sub _raw_object {

    my $self = shift;
    return unless $self->is_archive;
    return $self->unref( $self->raw_data->[1]{'$top'}[1]{root} );
}

=head2 object

If the plist is an Objective C object archive created with
C<NSKeyedArchiver> (see L</KEYED ARCHIVES>), returns the object
blessed into the corresponding class under
L<Data::Plist::Foundation::NSOjbect>.  Otherwise, returns undef.

=cut

sub object {
    my $self   = shift;

    require Data::Plist::Foundation::NSObject;

    return unless $self->is_archive;
    return $self->reify( $self->collapse( $self->_raw_object ) );
}

=head1 DEPENDENCIES

L<Class::ISA>, L<DateTime>, L<Digest::MD5>, L<Math::BigInt>,
L<MIME::Base64>, L<Scalar::Util>, L<Storable>, L<UNIVERSAL::isa>,
L<XML::Writer>

=head1 BUGS AND LIMITATIONS

No XML reader is included at current.

Please report any bugs or feature requests to
C<bug-Data-Plist@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.

=head1 AUTHORS

Alex Vandiver and Jacky Chang.

Based on plutil.pl, written by Pete Wilson <wilsonpm@gamewood.net>

=head1 LICENSE

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.  See L<perlartistic>.

=cut

1;
