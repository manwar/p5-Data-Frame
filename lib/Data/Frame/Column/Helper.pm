package Data::Frame::Column::Helper;
$Data::Frame::Column::Helper::VERSION = '0.001';
use strict;
use warnings;

use Moo;

has df => ( is => 'rw' ); # isa Data::Frame

use overload '&{}' => sub ($$) {
	my $self = shift;
	sub { $self->df->column(@_); };
};


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Data::Frame::Column::Helper

=head1 VERSION

version 0.001

=head1 AUTHOR

Zakariyya Mughal <zmughal@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Zakariyya Mughal.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
