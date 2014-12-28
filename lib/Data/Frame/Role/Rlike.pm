package Data::Frame::Role::Rlike;

use strict;
use warnings;
use Moo::Role;
use List::AllUtils;

sub head {
	my ($self, $n) = @_;
	my ($start, $stop);
	if( $n < 0 ) {
		$start = 0;
		$stop = $self->number_of_rows + $n - 1;
	} else {
		$start = 0;
		$stop  = $n - 1;
	}
	# clip to [ 0, number_of_rows-1 ]
	$start = List::AllUtils::max( 0, $start );
	$stop  = List::AllUtils::min( $self->number_of_rows-1, $stop );
	$self->select_rows( $start..$stop );
}

sub tail {
	my ($self, $n) = @_;
	my ($start, $stop);
	if( $n < 0 ) {
		$start = -$n;
		$stop = $self->number_of_rows - 1;
	} else {
		$start = $self->number_of_rows - $n;
		$stop = $self->number_of_rows - 1;
	}
	# clip to [ 0, number_of_rows-1 ]
	$start = List::AllUtils::max( 0, $start );
	$stop  = List::AllUtils::min( $self->number_of_rows-1, $stop );
	$self->select_rows( $start..$stop );
}

=method subset

    subset( CodeRef $select )

C<subset> is a helper method used to take the result of a the C<$select>
coderef and use the return value as an argument to
L<C<select_rows>/Data::Frame#select_rows>>.

The argument C<$select> is a CodeRef that is passed the Data::Frame
    $select->( $df ); # $df->subset( $select );
and returns a PDL. Within the scope of the C<$select> CodeRef, C<$_> is set to
a C<Data::Frame::Column::Helper> for the Data::Frame C<$df>.

    use Data::Frame::Rlike;
    use PDL;
    my $N  = 5;
    my $df = dataframe( x => sequence($N), y => 3 * sequence($N) );
    say $df->subset( sub {
                           ( $_->('x') > 1 )
                         & ( $_->('y') < 10 ) });
    # ---------
    #     x  y
    # ---------
    #  2  2  6
    #  3  3  9
    # ---------

=cut
sub subset($&) {
	# TODO
	my ($df, $cb) = @_;
	my $ch = $df->_column_helper;
	local *_ = \$ch;
	my $where = $cb->($df);
	$df->select_rows( $where->which );
}

1;