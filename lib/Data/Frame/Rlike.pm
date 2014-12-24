package Data::Frame::Rlike;
$Data::Frame::Rlike::VERSION = '0.001';
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(dataframe factor);

sub dataframe {
	Data::Frame->new(@_);
}

sub factor {
	PDL::Factor->new(@_);
}

# R-like
sub rbind {
	# TODO
	...
}

# R-like
sub subset($&) {
	# TODO
	my ($df, $cb) = @_;
	my $ch = $df->_column_helper;
	local *_ = \$ch;
	my $where = $cb->($df);
	$df->select_rows( $where->which );
}

*Data::Frame::subset = \&subset;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Data::Frame::Rlike

=head1 VERSION

version 0.001

=head1 AUTHOR

Zakariyya Mughal <zmughal@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Zakariyya Mughal.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
