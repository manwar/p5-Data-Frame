package Data::Frame;

# ABSTRACT: data frame implementation

use 5.016;
use warnings;

use Data::Frame::Class;
with 'MooX::Traits';

use failures qw{
	columns::mismatch columns::length columns::unbalanced
	rows::mismatch rows::length rows::unique
	column::exists column::name::string
	index index::exists
};

use Hash::Ordered;
use PDL::Basic qw(sequence);
use PDL::Core qw(pdl null);
use Data::Perl     ();
use Data::Perl::Collection::Array;
use List::AllUtils qw(each_arrayref pairgrep pairkeys pairmap pairwise);
use List::MoreUtils 0.423;
use PDL::Primitive ();
use PDL::Factor    ();
use PDL::SV        ();
use PDL::StringfiableExtension;
use Ref::Util qw(is_plain_arrayref is_plain_hashref);
use Scalar::Util qw(blessed looks_like_number);
use Sereal::Decoder;
use Sereal::Encoder;
use Text::Table::Tiny;
use Type::Params;
use Types::Standard qw(Any ArrayRef CodeRef CycleTuple HashRef Maybe Str);
use Types::PDL qw(Piddle);

use Data::Frame::Column::Helper;

use Data::Frame::Indexer qw(:all);
use Data::Frame::Types qw(:all);
use Data::Frame::Util qw(:all);

use overload (
    '""' => sub { $_[0]->string },
    '.=' => sub {                    # this is similar to PDL
        my ( $self, $other ) = @_;
        $self->assign($other);
    },
    '==' => sub {
        my ( $self, $other ) = @_;
        $self->_compare( $other, 'eq' );
    },
    'eq' => sub {
        my ( $self, $other ) = @_;
        $self->_compare( $other, 'eq' );
    },
    '!=' => sub {
        my ( $self, $other ) = @_;
        $self->_compare( $other, 'ne' );
    },
    '<' => sub {
        my ( $self, $other, $swap ) = @_;
        $self->_compare( $other, ( $swap ? 'ge' : 'lt' ) );
    },
    '<=' => sub {
        my ( $self, $other, $swap ) = @_;
        $self->_compare( $other, ( $swap ? 'gt' : 'le' ) );
    },
    '>' => sub {    # use '<' overload
        my ( $self, $other, $swap ) = @_;
        $swap ? ( $self < $other ) : ( $other < $self );
    },
    '>=' => sub {    # use '<=' overload
        my ( $self, $other, $swap ) = @_;
        $swap ? ( $self <= $other ) : ( $other <= $self );
    },
    fallback => 1
);

{
    # TODO temporary column role
    no strict 'refs';
    *{'PDL::number_of_rows'} = sub { $_[0]->getdim(0) };
    *{'Data::Perl::Collection::Array::number_of_rows'} = sub { $_[0]->count };
}

# Relative tolerance. This can be used for data frame comparison.
our $TOLERANCE_REL = undef;
our $doubleformat = '%.8g';

# Check if all columns have same length or have a length of 1.
around BUILDARGS($orig, $class : @args) {
    my %args = @args;   

    if ( my $columns = $args{columns} ) {
        my $columns_is_aref = Ref::Util::is_plain_arrayref($columns);
        my $columns_href;
        if ($columns_is_aref) {
            $columns_href = {@$columns};
        }
        else {
            $columns_href = $columns;
        }

        my @lengths    = map { $_->length } values %$columns_href;
        my $max_length = List::AllUtils::max(@lengths);
        for my $column_name ( sort keys %$columns_href ) {
            my $data = $columns_href->{$column_name};
            if ( $data->length != $max_length ) {
                if ( $data->length == 1 ) {
                    if ($columns_is_aref) {
                        my $idx = List::AllUtils::lastidx {
                            $_ eq $column_name
                        }
                        List::AllUtils::pairkeys(@$columns);
                        $columns->[ 2 * $idx + 1 ] = $data->repeat($max_length);
                    }
                    else {    # hashref
                        $columns->{$column_name} = $data->repeat($max_length);
                    }
                }
                else {
                    die
"Column piddles must all be same length or have a length of 1";
                }
            }
        }
    }
    return $class->$orig(\%args);
}

sub _trait_namespace { 'Data::Frame::Role' } # override for MooX::Traits

has _columns => ( is => 'ro', default => sub { Hash::Ordered->new; } );

has _row_names => ( is => 'rw', predicate => 1 );

with qw(
  Data::Frame::Role::Rlike
  Data::Frame::Partial::CSV
  Data::Frame::Partial::Eval
  Data::Frame::Partial::Sugar
);

sub BUILD {
	my ($self, $args) = @_;
	my $colspec = delete $args->{columns};

	if( defined $colspec ) {
		my @columns =
			  ref $colspec eq 'HASH'
			? map { ($_, $colspec->{$_} ) } sort { $a cmp $b } keys %$colspec
			: @$colspec;
		$self->add_columns(@columns);
	}

    my $row_names = $args->{row_names};
    if ( defined $row_names ) {
        $self->row_names($row_names);
    }

    $self->_initialize_sugar();
}

=method string

    string() # returns Str

Returns a string representation of the C<Data::Frame>.

=cut

method _string() {
    my $format_cell = sub {
        my ( $col, $ridx ) = @_;

        if ( $col->$_DOES('PDL::DateTime') ) {
            return $col->dt_at($ridx);
        }
        elsif ( $self->_is_numeric_column($col) ) {
            if ( $col->type >= PDL::float ) {

                # This is to fix some float precision problem with perl
                # of nvsize=16, which can cause $df->string to get untidy
                # float data to cause our test to fail.
                my $s = $col->slice($ridx)->squeeze->string;
                if ( $s eq 'BAD' ) {
                    return $s;
                }
                else {
                    return sprintf( $doubleformat, $s );
                }
            }
        }
        return $col->slice($ridx)->squeeze->string;
    };

    my @rows = ( [ '', @{ $self->column_names } ] );
    for my $r_idx ( 0 .. $self->number_of_rows - 1 ) {
        my $r = [
            $self->row_names->slice($r_idx)->squeeze->string,
            map {
                my $col = $self->nth_column($_);
                $format_cell->( $col, $r_idx );
            } 0 .. $self->number_of_columns - 1
        ];
        push @rows, $r;
    }
    {
        # clear column separators
        local $Text::Table::Tiny::COLUMN_SEPARATOR = '';
        local $Text::Table::Tiny::CORNER_MARKER    = '';

        Text::Table::Tiny::table( rows => \@rows, header_row => 1 )
    }
}

method string( $row_limit = 10 ) {
    if ( $row_limit < 0 ) {
        $row_limit = $self->nrow;
    }

    my $more_rows = $self->nrow - $row_limit;
    my $df        = $more_rows > 0 ? $self->head($row_limit) : $self;
    my $text      = $df->_string() . "\n";
    if ( $more_rows > 0 ) {
        $text .= "# ... with $more_rows more rows\n";
    }

    return $text;
}

=method number_of_columns

    number_of_columns() # returns Int

Returns the count of the number of columns in the C<Data::Frame>.

=method ncol

    ncol()

This is same as C<number_of_columns>.

=method length

    length()

This is same as C<number_of_columns>.

=cut

method number_of_columns() {
	return scalar($self->_columns->keys);
}

*ncol   = \&number_of_columns;
*length = \&number_of_columns;

=method number_of_rows

    number_of_rows() # returns Int

Returns the count of the number of rows in the C<Data::Frame>.

=method nrow

    nrow()

This is same as C<number_of_rows>.


=cut

sub number_of_rows {
	my ($self) = @_;
	if( $self->number_of_columns ) {
		return $self->nth_column(0)->length;
	}
	0;
}

*nrow = \&Data::Frame::number_of_rows;

=method dims
    
    dims()

Returns the dimensions of the data frame object, in an array of C<($nrow, $ncol)>.

=method shape

    shape()

Similar to C<dims> but returns a piddle.

=cut

method dims () {
    return ( $self->nrow, $self->ncol );
}

method shape () {
    return pdl( $self->dims );
}

=method at
    
    my $column_piddle = $df->at($column_indexer);
    my $cell_value = $df->at($row_indexer, $column_indexer);

If only one argument is given, it would treat the argument as column
indexer to get the column.
If two arguments are given, it would treat the arguments for row
indexer and column indexer respectively to get the cell value.

If a given argument is non-indexer, it would try guessing whether the
argument is numeric or not, and coerce it by either C<indexer_s()> or
C<indexer_i()>.

=cut

method _indexer_to_indices ($indexer, $row_or_column) {
    if ( $indexer->$_isa('Data::Frame::Indexer::Integer') ) {
        return $indexer->indexer;
    }
    else {
        my $names_getter = "${row_or_column}_names";
        my @names        = $self->$names_getter()->flatten;
        return $indexer->indexer->map(
            sub {
                my ($name) = @_;
                my $ridx = List::AllUtils::firstidx { $name eq $_ } @names;
                if ( $ridx < 0 ) {
                    die "Cannot find $row_or_column name '$name'.";
                }
                return $ridx;
            }
        );
    }
}

method _cindexer_to_indices (Indexer $indexer) {
    return $self->_indexer_to_indices( $indexer, 'column' );
}

method _rindexer_to_indices (Indexer $indexer) {
    if ( $indexer->$_DOES('Data::Frame::Indexer::Label') ) {
        die "select_rows() does not yet support label indexer";
    }

    return $self->_indexer_to_indices( $indexer, 'row' );
}

method at (@rest) {
    my ( $rindexer, $cindexer ) = $self->_check_slice_args(@_);

    my $cindex = $cindexer->indexer->[0];
    my $col;
    if ( $cindexer->$_DOES('Data::Frame::Indexer::Integer') ) {
        $col = $self->nth_column($cindex);
    }
    else {    # Label;
        $col = $self->column($cindex);
    }

    if ( defined $rindexer ) {
        return $col->at( $rindexer->indexer->[0] );
    }
    else {
        return $col;
    }
}

=method exists

    exists($col_name)

Returns true if there exists a column named C<$col_name> in the data frame
object, false otherwise.

=method delete

    delete($col_name)

In-place delete column given by C<$col_name>.

=method rename

    rename($hashref_or_coderef)

In-place rename columns.

=method select_columns

    select_columns($indexer) 

Returns a new data frame object which has the columns selected by C<$indexer>.

If a given argument is non-indexer, it would coerce it by C<indexer_s()>.

=cut

# Public methods other than slice() shall be non-lvalue.
sub select_columns { shift->_select_columns(@_); }

method exists ($col_name) {
    $self->_columns->exists($col_name);
}

method delete ($col_name) {
    $self->_columns->delete($col_name);
}

method rename ((HashRef | CodeRef) $href_or_coderef) {
    my $f =
      Ref::Util::is_plain_coderef($href_or_coderef)
      ? $href_or_coderef
      : sub { $href_or_coderef->{ $_[0] } };
    my $new_names = $self->names->map( sub { $f->($_) // $_ } );
    $self->names($new_names);
    return $self;
}

=method set

    set(Indexer $col_name, Piddle0Dor1D $data)

Sets data to column. If C<$col_name> does not exist, it would add a new column.

=cut

method set ($indexer, $data) {
    state $check =
      Type::Params::compile( Indexer->plus_coercions(IndexerFromLabels),
        Piddle0Dor1D->plus_coercions( ArrayRef, sub { PDL::SV->new($_) } ) );
    ($indexer) = $check->( $indexer, $data );

    if ( $data->length == 1 ) {
        $data = $data->repeat( $self->nrow );
    }

    # Only Label indexer can be used to add new columns.
    my $name;
    if ( $indexer->$_DOES('Data::Frame::Indexer::Label') ) {
        $name = $indexer->indexer->[0];
    }
    else {
        my $cidx = $indexer->indexer->[0];
        if ( $cidx >= $self->ncol ) {
            die "Invalid column index: $cidx";
        }
        $name = $self->column_names->at($cidx);
    }

    if ( $self->exists($name) ) {
        $self->_column_validate( $name => $data );
        $self->_columns->set( $name => $data );
    }
    else {
        $self->add_column( $name, $data );
    }
    return;
}

=method isempty

    isempty()

Returns true if the data frame has no rows.

=cut

method isempty () { $self->nrow == 0; }

=method nth_columm

    number_of_rows(Int $n) # returns a column

Returns column number C<$n>. Supports negative indices (e.g., $n = -1 returns
the last column).

=cut
# supports negative indices
method nth_column($index) {
	failure::index->throw({
			msg => "requires index",
			trace => failure->croak_trace
		}) unless defined $index;
	failure::index::exists->throw({
			msg => "column index out of bounds",
			trace => failure->croak_trace,
		}) if $index >= $self->number_of_columns;
	# fine if $index < 0 because negative indices are supported
	return ($self->_columns->values)[$index];
}


=method column_names

    column_names() # returns an ArrayRef

    column_names( @new_column_names ) # returns an ArrayRef

Returns an C<ArrayRef> of the names of the columns.

If passed a list of arguments C<@new_column_names>, then the columns will be
renamed to the elements of C<@new_column_names>. The length of the argument
must match the number of columns in the C<Data::Frame>.

=method col_names

    col_names($new_names)

This is same as C<column_names>.

=method names

    names($new_names)

This is same as C<column_names>.

=cut

method column_names(@rest) {
    my @colnames =
      (
        @rest == 1
          and ( Ref::Util::is_plain_arrayref( $rest[0] )
            or $rest[0]->$_can('flatten') )
      )
      ? $rest[0]->flatten
      : @rest;

	if( @colnames ) {
        unless (@colnames == $self->length) {
			failure::columns::length->throw({
					msg => "incorrect number of column names",
					trace => failure->croak_trace,
				});
        }
        # rename column names
        my @values = $self->_columns->values;
        $self->_columns->clear;
        $self->_columns->push( List::AllUtils::zip( @colnames, @values ) );
	}
	return [ $self->_columns->keys ];
}

*col_names = \&column_names;
*names = \&column_names;

=method row_names

    row_names() # returns a PDL

    row_names( Array @new_row_names ) # returns a PDL

    row_names( ArrayRef $new_row_names ) # returns a PDL

    row_names( PDL $new_row_names ) # returns a PDL

Returns an C<ArrayRef> of the names of the columns.

If passed a argument, then the rows will be renamed. The length of the argument
must match the number of rows in the C<Data::Frame>.

=cut
sub row_names {
	my ($self, @rest) = @_;
	if( @rest ) {
		# setting row names
		my $new_rows;
        if ( ref $rest[0] ) {
            if ( ref $rest[0] eq 'ARRAY' ) {
                $new_rows = Data::Perl::array( @{ $rest[0] } );
            }
            elsif ( $rest[0]->isa('PDL') ) {

                # TODO just run uniq?
                $new_rows = Data::Perl::array( @{ $rest[0]->unpdl } );
            }
            else {
                $new_rows = Data::Perl::array(@rest);
            }
        }
        else {
            $new_rows = Data::Perl::array(@rest);
        }

		failure::rows::length->throw({
				msg => "invalid row names length",
				trace => failure->croak_trace,
			}) if $self->number_of_rows != $new_rows->number_of_rows;
		failure::rows::unique->throw({
				msg => "non-unique row names",
				trace => failure->croak_trace,
			}) if $new_rows->number_of_rows != $new_rows->uniq->number_of_rows;

		return $self->_row_names( PDL::SV->new($new_rows) );
	}
	if( not $self->_has_row_names ) {
		# if it has never been set before
		return sequence($self->number_of_rows);
	}
	# else, if row_names has been set
	return $self->_row_names;
}

sub _make_actual_row_names {
	my ($self) = @_;
	if( not $self->_has_row_names ) {
		$self->_row_names( $self->row_names );
	}
}

=method column

    column( Str $column_name )

Returns the column with the name C<$column_name>.

=cut

method column($colname) {
	failure::column::exists->throw({
			msg => "column $colname does not exist",
			trace => failure->croak_trace,
		}) unless $self->exists( $colname );
	return $self->_columns->get( $colname );
}

sub _column_validate {
	my ($self, $name, $data) = @_;
	if( $name =~ /^\d+$/  ) {
		failure::column::name::string->throw({
				msg => "invalid column name: $name can not be an integer",
				trace => failure->croak_trace,
			});
	}
	if( $self->number_of_columns ) {
		if( $data->length != $self->number_of_rows ) {
			failure::rows::length->throw({
					msg => "number of rows in column is @{[ $data->length ]}; expected @{[ $self->number_of_rows ]}",
					trace => failure->croak_trace,
				});
		}
	}
	1;
}

=method add_columns

    add_columns( Array @column_pairlist )

Adds all the columns in C<@column_pairlist> to the C<Data::Frame>.

=cut

method add_columns(@columns) {
	failure::columns::unbalanced->throw({
			msg => "uneven number of elements for column specification",
			trace => failure->croak_trace,
		}) unless @columns % 2 == 0;
	for ( List::AllUtils::pairs(@columns) ) {
		my ( $name, $data ) = @$_;
		$self->add_column( $name => $data );
	}
}

=method add_column

    add_column(Str $name, $data)

Adds a single column to the C<Data::Frame> with the name C<$name> and data
C<$data>.

=cut

sub add_column {
	my ($self, $name, $data) = @_;
	failure::column::exists->throw({
			msg => "column $name already exists",
			trace => failure->croak_trace,
		}) if $self->exists( $name );

	# TODO apply column role to data
	$data = PDL::SV->new( $data ) if ref $data eq 'ARRAY';

	$self->_column_validate( $name => $data);
	$self->_columns->push( $name => $data );
}

=method select_rows

    select_rows( Indexer $indexer)

    # below types would be coerced to Indexer
    select_rows( Array @which )
    select_rows( ArrayRef $which )
    select_rows( Piddle0Dor1D $which )

The argument C<$indexer> is an "Indexer", as defined in L<Data::Frame::Types>.
C<select_rows> returns a new C<Data::Frame> that contains rows that match
the indices specified by C<$indexer>.

This C<Data::Frame> supports PDL's data flow, meaning that changes to the
values in the child data frame columns will appear in the parent data frame.

If no indices are given, a C<Data::Frame> with no rows is returned.

=cut
# R
# > iris[c(1,2,3,3,3,3),]
# PDL
# $ sequence(10,4)->dice(X,[0,1,1,0])

method select_rows(@rest) {
    my $indexer = indexer_i(@rest);
    return $self unless defined $indexer;

    my $indices = $self->_rindexer_to_indices($indexer);

	my $which = PDL::Core::topdl($indices); # ensure it is a PDL

	my $colnames = $self->column_names;
	my $colspec = [ map {
		( $colnames->[$_] => $self->nth_column($_)->dice($which) )
	} 0..$self->number_of_columns-1 ];

	$self->_make_actual_row_names;
	my $select_df = $self->new(
		columns => $colspec,
		_row_names => $self->row_names->dice( $which ) );
	$select_df;
}

=method sample

    sample($n)

Get a random sample of rows from the data frame object, as a new data frame.

    my $sample_df = $df->sample(100);

=cut

method sample ($n) {
    if ($n > $self->nrow) {
        die "sample size is larger than nrow";
    }

    my $indices = [ List::MoreUtils::samples($n, (0 .. $self->nrow-1)) ];
    return $self->select_rows($indices);
}

=method merge

    merge($df)

=method cbind

    cbind($df)

This is same as C<merge()>.

=method append

    append($df)

=method rbind
    
    rbind($df)

This is same as C<append()>.

=method transform

    transform($func)

Apply a function to columns of the data frame, and returns a new data
frame object. 

C<$func> can be one of the following, 

=for :list
* A function coderef. It would be applied to all columns.
* A hashref of C<{ $column_name =E<gt> $coderef, ... }>. It allows to apply
the function to the specified columns. The raw data frame's columns not 
existing in the hashref be retained unchanged. Hashref keys not yet
existing in the raw data frame can be used for creating new columns.
* An arrayref like C<[ $column_name =E<gt> $coderef, ... ]>. In this mode
it's similar as the hasref above, but newly added columns would be in order.

In any of the forms of C<$func> above, if a new column data is calculated
to be C<undef>, or in the mappings like hashref or arrayref C<$coderef> is
an explicit C<undef>, then the column would be removed from the result
data frame.

Here are some examples, 

=over 4

=item Operate on all data of the data frame,

    my $df_new = $df->transform(
            sub {
                my ($col, $df) = @_;
                $col * 2;
            } );

=item Change some of the existing columns, 

    my $df_new = $df->transform( {
            foo => sub {
                my ($col, $df) = @_;
                $col * 2;
            },
            bar => sub {
                my ($col, $df) = @_;
                $col * 3;
            } );
 
=item Add a new column from existing data,
    
    # Equivalent to: 
    # do { my $x = $mtcars->copy;
    #      $x->set('kpg', $mtcars->at('mpg') * 1.609); $x; };
    my $mtcars_new = $mtcars->transform(
            kpg => sub { 
                my ($col, $df) = @_;    # $col is undef in this case
                $df->at('mpg') * 1.609,
            } );

=back

=cut

method merge (DataFrame $df) {
    my $class   = ref($self);
    my $columns = [
        $self->names->map( sub { $_ => $self->at($_) } )->flatten,
        $df->names->map( sub { $_ => $df->at($_) } )->flatten
    ];
    return $class->new(
        columns   => $columns,
        row_names => $self->row_names
    );
}
*cbind = \&merge;

method append (DataFrame $df) {
    if ( $df->nrow == 0 ) {                     # $df is empty
        return $self->clone();
    }
    if ( $self->column_names->length == 0) {    # $self has no columns
        return $df->clone;
    }

    my $class   = ref($self);
    my $columns = $self->names->map(
        sub {
            my $col = $self->at($_);
            # use glue() as PDL's append() cannot handle bad values
            $_ => $col->glue( 0, $df->at($_) );
        }
    );
    return $class->new( columns => $columns );
}
*rbind = \&append;

method transform ($func) {
    state $check = Type::Params::compile(
        (
            CodeRef | ( HashRef [ Maybe [CodeRef] ] ) |
              ( CycleTuple [ Str, Maybe [CodeRef] ] )
        )
    );
    ($func) = $check->($func);

    my $class = ref($self);

    my @columns;
    if ( Ref::Util::is_coderef($func) ) {
        @columns =
          $self->names->map( sub {
            $_ => $func->( $self->at($_), $self );
          } )->flatten;
    }
    else {    # hashref or arrayref
        my $column_names = $self->names;
        my $hashref;
        my @new_column_names;
        if ( Ref::Util::is_hashref($func) ) {
            $hashref = $func;
            @new_column_names =
              grep { !$self->exists($_) } sort( keys %$hashref );
        }
        else {    # arrayref
            $hashref = {@$func};
            @new_column_names = grep { !$self->exists($_) } ( pairkeys @$func );
        }

        @columns = $column_names->map(
            sub {
                my $f = exists($hashref->{$_}) ? $hashref->{$_} : sub { $_[0] };
                $f //= sub { undef };
                $_ => $f->( $self->at($_), $self );
            }
        )->flatten;
        push @columns,
          map { my $f = $hashref->{$_}; $_ => $f->( undef, $self ) }
          @new_column_names;
    }

    my %columns_to_drop = @columns;
    %columns_to_drop = pairgrep { not defined $b } %columns_to_drop;

    return $class->new(
        columns   => [ pairgrep { !exists($columns_to_drop{$a}) } @columns ],
        row_names => $self->row_names,
    );
}

=method split

    split(Piddle1D $factor)

Splits the data in into groups defined by C<$factor>.
In a scalar context it returns a hashref mapping value to data frame.
In a list context it returns an assosiative array, which is ordered by
values in C<$factor>.

Note that C<$factor> does not necessarily to be PDL::Factor.

=cut

method split (Piddle0Dor1D $factor) {
    if ($factor->$_DOES('PDL::Factor')) {
        $factor = $factor->{PDL};
    }
    my $uniq_values = $factor->$_call_if_can('uniq')
      // [ List::AllUtils::uniq( $factor->flatten ) ];

    my @rslt = map {
        my $indices = PDL::Primitive::which( $factor == $_ );
        $_ => $self->select_rows($indices);
    } $uniq_values->flatten;

    return (wantarray ? @rslt : { @rslt });
}

=method slice

    my $subset1 = $df->slice($row_indexer, $column_indexer);

    # Note that below two cases are different.
    my $subset2 = $df->slice($column_indexer);
    my $subset3 = $df->slice($row_indexer, undef);

Returns a new dataframe object which is a slice of the raw data frame.

This method returns an lvalue which allows PDL-like C<.=> assignment for
changing a subset of the raw data frame. For example,

    $df->slice($row_indexer, $column_indexer) .= $another_df;
    $df->slice($row_indexer, $column_indexer) .= $piddle;

If a given argument is non-indexer, it would try guessing if the argument
is numeric or not, and coerce it by either C<indexer_s()> or C<indexer_i()>.

=cut

# below lvalue methods are for slice()
sub _column : lvalue     { my $col = shift->column(@_);     return $col; }
sub _nth_column : lvalue { my $col = shift->nth_column(@_); return $col; }

method _select_columns (@rest) : lvalue {
    my $indexer = indexer_s(@rest);
    return $self if ( not defined $indexer or $indexer->indexer->length == 0 );

    my $indices      = $self->_cindexer_to_indices($indexer);
    my $column_names = $self->column_names;
    return ref($self)->new(
        columns => $indices->map(
            sub { $column_names->at($_) => $self->_nth_column($_) }
        ),
        row_names => $self->row_names
    );
}

classmethod _check_slice_args (@rest) {
    state $check_labels =
      Type::Params::compile( Indexer->plus_coercions(IndexerFromLabels) );
    state $check_indices =
      Type::Params::compile( Indexer->plus_coercions(IndexerFromIndices) );

    my ( $row_indexer, $column_indexer ) =
      map {
        if ( !defined($_) ) {
            undef;
        }
        elsif ( Indexer->check($_) ) {
            $_;
        }
        else {
            my $p = guess_and_convert_to_pdl($_);
            ($p->$_DOES('PDL::SV') ? $check_labels : $check_indices)->($p);
        }
      } ( @rest > 1 ? @rest : ( undef, $rest[0] ) );
    return ( $row_indexer, $column_indexer );
}

method slice(@rest) : lvalue {
    my ( $rindexer, $cindexer ) = $self->_check_slice_args(@rest);
    my $new_df = $self->select_rows($rindexer);
    $new_df = $new_df->select_columns($cindexer);
    return $new_df;
}

=method assign

    assign( (DataFrame|Piddle) $x )

Assign another data frame or a piddle to this data frame for in-place change.

C<$x> can be,

=for :list
*A data frame object having the same dimensions and column names as C<$self>.
*A piddle having the same number of elements as C<$self>.

This method is internally used by the C<.=> operation, below are same,

    $df->assign($x);
    $df .= $x;

=cut

method assign ((DataFrame | Piddle) $x) {
    if ( DataFrame->check($x) ) {
        unless ( ( $self->shape == $x->shape )->all ) {
            die "Cannot assign a data frame of different shape.";
        }
        for my $name ( $self->names->flatten ) {
            my $col = $self->at($name);
            $col .= $x->at($name);
        }
    }
    elsif ( $x->$_DOES('PDL') ) {
        my @dims = $self->dims;

        unless ( $x->ndims == 1 and $x->dim(0) == $dims[0] * $dims[1]
            or $x->ndims == 2
            and $x->dim(0) == $dims[0]
            and $x->dim(1) == $dims[1] )
        {
            die;
        }

        for my $i ( 0 .. $self->length - 1 ) {
            $self->_nth_column($i) .=
              $x->flat->slice( pdl( 0 .. $dims[0] - 1 ) + $i * $dims[1] );
        }
    }
    return $self;
}

=method is_numeric_column

    is_numeric_column($column_name_or_idx)

=cut

method is_numeric_column ($column_name_or_idx) {
    my $column = $self->at($column_name_or_idx);
    return $self->_is_numeric_column($column);
}

sub _is_numeric_column {
    my ($self, $piddle) = @_;
    return !is_discrete($piddle);
}

=method sort

    sort($by_columns, $ascending=true)

Sort rows for given columns.
Returns a new data frame.

    my $df_sorted1 = $df->sort( [qw(a b)], true );
    my $df_sorted2 = $df->sort( [qw(a b)], [1, 0] );
    my $df_sorted3 = $df->sort( [qw(a b)], pdl([1, 0]) );

=method sorti

Similar as this class's C<sort()> method but returns a piddle for row indices.

=cut

method sort ($by_columns, $ascending=true) {
    return $self->clone if $by_columns->length == 0;

    my $row_indices = $self->sorti( $by_columns, $ascending );
    return $self->select_rows($row_indices);
}

method sorti ($by_columns, $ascending=true) {
    if (Ref::Util::is_plain_arrayref($ascending)) {
        $ascending = logical($ascending);
    }

    return pdl( [ 0 .. $self->nrow - 1 ] ) if $by_columns->length == 0;

    my $is_number = $by_columns->map( sub { $self->is_numeric_column($_) } );
    my $compare = sub {
        my ( $a, $b ) = @_;
        for my $i ( 0 .. $#$is_number ) {
            my $rslt = (
                  $is_number->[$i]
                ? $a->[$i] <=> $b->[$i]
                : $a->[$i] cmp $b->[$i]
            );
            next if $rslt == 0;

            my $this_ascending = $ascending->$_call_if_can( 'at', $i )
              // $ascending;
            return ( $this_ascending ? $rslt : -$rslt );
        }
        return 0;
    };

    my $ea =
      each_arrayref( @{ $by_columns->map( sub { $self->at($_)->unpdl } ) } );
    my @sorted_row_indices = map { $_->[0] }
      sort { $compare->( $a->[1], $b->[1] ) }
      map {
        my @row_data = $ea->();
        [ $_, \@row_data ];
      } ( 0 .. $self->nrow - 1 );

    return pdl( \@sorted_row_indices );
}

=method uniq

    uniq()

Returns a new data frame, which has the unique rows. The row names
are from the first occurrance of each unique row in the raw data frame.

=cut

method _serialize_row ($i) {
    state $sereal = Sereal::Encoder->new();
    my @row_data = map { $self->at($_)->at($i) } @{ $self->column_names };
    return $sereal->encode( \@row_data );
}

method uniq () {
    my %uniq;
    my @uniq_ridx;
    for my $i ( 0 .. $self->nrow - 1 ) {
        my $key = $self->_serialize_row($i);
        unless ( exists $uniq{$key} ) {
            $uniq{$key} = 1;
            push @uniq_ridx, $i;
        }
    }
    return $self->select_rows( \@uniq_ridx );
}

=method id

    id()

Compute a unique numeric id for each unique row in a data frame.

=cut

method id () {
    my %uniq_serialized;
    my @uniq_rindices;
    for my $ridx ( 0 .. $self->nrow - 1 ) {
        my $key = $self->_serialize_row($ridx);
        if ( not exists $uniq_serialized{$key} ) {
            $uniq_serialized{$key} = [];
            push @uniq_rindices, $ridx;
        }
        push @{ $uniq_serialized{$key} }, $ridx;
    }

    my %rindex_to_serialized = pairmap { $b->[0] => $a } %uniq_serialized;
    my $rindices_sorted =
      $self->select_rows( \@uniq_rindices )->sorti( $self->names );

    my $rslt = PDL::Core::zeros( $self->nrow );
    for my $i ( 1 .. $#uniq_rindices ) {
        my $serialized =
          $rindex_to_serialized{ $uniq_rindices[ $rindices_sorted->at($i) ] };
        my $rindices = $uniq_serialized{$serialized};
        $rslt->slice( pdl($rindices) ) .= $i;
    }
    return $rslt;
}

=method copy 

    copy()

Make a deep copy of this data frame object.

=method clone
    
    clone()

This is same as C<copy()>.

=cut

method copy () { 
    return ref($self)->new(
        columns   => $self->names->map( sub { $_ => $self->at($_)->copy } ), 
        row_names => $self->row_names->copy
    );
}
*clone = \&copy;

=method which

    which(:$bad_to_val=undef, :$ignore_both_bad=true)

Returns a pdl of C<[[col_idx, row_idx], ...]>, like the output of
L<PDL::Primitive/whichND>.

=cut

method which (:$bad_to_val=undef, :$ignore_both_bad=true) {
    my $coordinates = [ 0 .. $self->ncol - 1 ]->map(
        fun($cidx)
        {
            my $column = $self->at( indexer_i( [$cidx] ) );
            my $both_bad =
                $self->DOES('Data::Frame::Role::CompareResult')
              ? $self->both_bad->at( indexer_i( [$cidx] ) )
              : undef;

            if ( defined $bad_to_val ) {
                $column = $column->setbadtoval($bad_to_val);
            }

            my $indices_false = PDL::Primitive::which(
                defined $both_bad ? ( !$both_bad & $column ) : $column );
            return $indices_false->unpdl->map( sub { [ $_, $cidx ] } )->flatten;
        }
    );
    return pdl($coordinates);
}

method _compare ($other, $mode) {
    my $class = ref($self);

    state $gen_fcompare = sub {
        my ($f) = @_;

        return sub {
            my ( $col, $x ) = @_;
            my $col_isbad = $col->isbad;
            my $x_isbad   = $x->$_call_if_can('isbad') // 1;
            my $both_bad  = ( $col_isbad & $x_isbad );

            my $rslt = $f->( $col, $x );
            return ( $rslt, $both_bad );
        }
    };

    state $fcompare_exact = {
        pairmap { $a => $gen_fcompare->($b) }
        (
            eq => sub { $_[0] == $_[1] },
            ne => sub { $_[0] != $_[1] },
            lt => sub { $_[0] < $_[1] },
            le => sub { $_[0] <= $_[1] },
            gt => sub { $_[0] > $_[1] },
            ge => sub { $_[0] >= $_[1] },
        )
    };

    # Absolute tolerance, calculated from multiplying $TOLERANCE_REL 
    #  with max abs of the two values.
    state $_tolerance = sub {
        my ( $col, $x ) = @_;
        my $a = $col->abs;
        my $b = ref($x) ? $x->abs : abs($x);
        return ifelse( $a > $b, $a, $b ) * $TOLERANCE_REL;
    };

    state $fcompare_float = {
        pairmap { $a => $gen_fcompare->($b) }
        (
            eq => sub { ( $_[0] - $_[1] )->abs < $_tolerance->(@_) },
            ne => sub { ( $_[0] - $_[1] )->abs > $_tolerance->(@_) },
            lt => sub { ( $_[0] - $_[1] ) < $_tolerance->(@_) },
            le => sub { ( $_[0] - $_[1] ) < $_tolerance->(@_) },
            gt => sub { ( $_[0] - $_[1] ) > $_tolerance->(@_) },
        )
    };

    state $same_names = sub {
        my ( $a, $b ) = @_;
        return 0 unless $a->length eq $b->length;
        return (
            List::AllUtils::all { $a->at($_) eq $b->at($_) }
            ( 0 .. $a->length - 1 )
        );
    };

    my $compare_column = sub {
        my ( $name, $x ) = @_;

        my $col = $self->at($name);

        my $fcompare;
        if ( $self->is_numeric_column($name) ) {
            $fcompare =
              (
                not defined $TOLERANCE_REL
                  or ( $col->type < PDL::float
                    and ( !ref($x) and $x->type < PDL::float ) )
              )
              ? $fcompare_exact->{$mode}
              : $fcompare_float->{$mode};
        }
        elsif ( $col->$_DOES('PDL::SV') ) {
            $fcompare = $fcompare_exact->{$mode};
        }
        elsif ( $col->$_DOES('PDL::Factor') ) {
            $fcompare = $fcompare_exact->{$mode};
        }

        unless ($fcompare) {
            die qq{Different types found on column "$name"};
        }

        return $fcompare->( $col, $x );
    };

    my $result_columns;
    if ( $other->$_DOES('Data::Frame') ) {
        unless ( $same_names->( $self->column_names, $other->column_names ) ) {
            failure::columns::mismatch->throw;
        }
        unless ( $same_names->( $self->row_names, $other->row_names ) ) {
            failure::rows::mismatch->throw;
        }
        $result_columns = {
            $self->names->map(
                sub { $_ => [ $compare_column->( $_, $other->at($_) ) ]; }
            )->flatten
        };
    }
    else {
        unless ( looks_like_number($other)
            or ( $other->$_DOES('PDL') and $other->length == 1 ) )
        {
            die "Cannot compare data frame with non-number or non-data-frame.";
        }
        $result_columns = {
            $self->names->map(
                sub { $_ => [ $compare_column->( $_, $other ) ]; }
            )->flatten
        };
    }

    my $both_bad =
      $class->new( columns =>
          $self->names->map( sub { $_ => $result_columns->{$_}->[1] } ) );
    return $class->with_traits('CompareResult')->new(
        columns =>
          $self->names->map( sub { $_ => $result_columns->{$_}->[0] } ),
        both_bad => $both_bad,
    );
}

sub _column_helper {
	my ($self) = @_;
	Data::Frame::Column::Helper->new( dataframe => $self );
}

1;

__END__

=pod
=encoding utf8

=head1 STATUS

This library is current experimental.

=head1 SYNOPSIS

    use Alt::Data::Frame::ButMore;
    use Data::Frame;
    use PDL;

    my $df = Data::Frame->new(
            columns => [
                z => pdl(1, 2, 3, 4),
                y => ( sequence(4) >= 2 ) ,
                x => [ qw/foo bar baz quux/ ],
            ] );

    say $df;
    # ---------------
    #     z  y  x
    # ---------------
    #  0  1  0  foo
    #  1  2  0  bar
    #  2  3  1  baz
    #  3  4  1  quux
    # ---------------

    say $df->at(0);
    # [1 2 3 4]

    say $df->select_rows( 3,1 );
    # ---------------
    #     z  y  x
    # ---------------
    #  3  4  1  quux
    #  1  2  0  bar
    # ---------------

    $df->slice( [0,1], ['z', 'y'] ) .= pdl( 4,3,2,1 );
    say $df;
    # ---------------
    #     z  y  x
    # ---------------
    #  0  4  2  foo
    #  1  3  1  bar
    #  2  3  1  baz
    #  3  4  1  quux
    # ---------------

=head1 DESCRIPTION

It's been too long I cannot reach ZMUGHAL.
So here I release my L<Alt> implenmentation.  

This implements a data frame container that uses L<PDL> for individual columns.
As such, it supports marking missing values (C<BAD> values).

=head1 CONSTRUCTION

    new( (ArrayRef | HashRef) :$columns,
         ArrayRef :$row_names=undef )

Creates a new C<Data::Frame> when passed the following options as a
specification of the columns to add:

=over 4

=item * columns => ArrayRef $columns_array

When C<columns> is passed an C<ArrayRef> of pairs of the form

    $columns_array = [
        column_name_z => $column_01_data, # first column data
        column_name_y => $column_02_data, # second column data
        column_name_x => $column_03_data, # third column data
    ]

then the column data is added to the data frame in the order that the pairs
appear in the C<ArrayRef>.

=item * columns => HashRef $columns_hash

    $columns_hash = {
        column_name_z => $column_03_data, # third column data
        column_name_y => $column_02_data, # second column data
        column_name_x => $column_01_data, # first column data
    }

then the column data is added to the data frame by the order of the keys in the
C<HashRef> (sorted with a stringwise C<cmp>).

=item * row_names => ArrayRef $row_names

=back

=head1 MISCELLANEOUS FEATURES

=head2 SERIALIZATION

See L<Data::Frame::Partial::CSV>

=head2 SYNTAX SUGAR

See L<Data::Frame::Partial::Sugar>

=head2 TIDY EVALUATION

This feature is somewhat similar to R's tidy evaluation.

See L<Data::Frame::Partial::Eval>.

=head1 SEE ALSO

=over 4

=item * L<Alt>

=item * L<R manual: data.frame|https://stat.ethz.ch/R-manual/R-devel/library/base/html/data.frame.html>.

=item * L<Statistics::NiceR>

=item * L<PDL>

=back

=cut
