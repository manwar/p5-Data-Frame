#!perl

use strict;
use warnings;

use Data::Dumper;
use PDL::Core qw(pdl);
use PDL::Lite;
use PDL::SV;

use Test2::V0;
use Test2::Tools::PDL;

subtest bad => sub {
    my $p1 = PDL::SV->new( [qw(foo bar baz)] );
    $p1->setbadat(1);

    ok( $p1->badflag, 'badflag() after setbadat()' );
    pdl_is( $p1->isbad,  pdl( [ 0, 1, 0 ] ), 'isbad' );
    pdl_is( $p1->isgood, pdl( [ 1, 0, 1 ] ), 'isgood' );

    my $p2 = $p1->setbadif( pdl( [ 0, 0, 1 ] ) );

    ok( $p2->badflag, 'badflag() after setbadif()' );
    pdl_is( $p2->isbad, pdl( [ 0, 1, 1 ] ), 'isbad() after setbadif' );

    is( [ @{ $p2->_internal }[ 0, 2 ] ],
        [qw(foo baz)], '_internal copied after setbadif' );

    my $p3 = PDL::SV->new( [ [qw(foo bar baz)], [qw(qux quux quuz)] ] );
    $p3 = $p3->setbadif( pdl( [ [ 0, 0, 1 ], [ 0, 1, 0 ] ] ) );
    pdl_is( $p3->isbad, pdl( [ [ 0, 0, 1 ], [ 0, 1, 0 ] ] ),
        '$pdlsv_1d->setbadif' );

    my $p3a = $p3->setbadtoval('hello');
    ok( !$p3a->badflag, 'badflag() after setbadtoval()' );
    is( $p3a->unpdl, [ [qw(foo bar hello)], [qw(qux hello quuz)] ],
        '$pdlsv_nd->setbadtoval' );
};

subtest at => sub {
    my $p1 = PDL::SV->new( [qw(foo bar baz)] )->setbadat(1);

    is( $p1->at(0), 'foo', 'at' );
    is( $p1->at(1), 'BAD', 'at a bad value' );
};

subtest slice => sub {
    my $p1 = PDL::SV->new( [qw(foo bar baz)] )->setbadat(1);

    pdl_is( $p1->slice( [ 1, 2 ] ),
        PDL::SV->new( [qw(bar baz)] )->setbadat(0) );
};

subtest unpdl => sub {
    my $p1 = PDL::SV->new( [qw(foo bar baz)] )->setbadat(1);

    is( $p1->unpdl, [qw(foo BAD baz)], '1D object' );

    my $p2 = PDL::SV->new( [ [qw(foo bar baz)], [qw(qux quux quuz)] ] )
      ->setbadif( pdl( [ [ 0, 0, 1 ], [ 0, 1, 0 ] ] ) );
    is( $p2->unpdl, [ [qw(foo bar BAD)], [qw(qux BAD quuz)] ], 'ND object' );

    my $p3 = $p1->slice( pdl( [ 1, 2 ] ) );
    is( $p3->unpdl, [qw(BAD baz)], '$slice->unpdl' );
};

subtest match_regexp => sub {
    my $p1 = PDL::SV->new( [qw(foo bar baz)] )->setbadat(1);

    pdl_is(
        $p1->match_regexp(qr/ba/),
        pdl( [ 0, 1, 1 ] )->setbadat(1),
        '1D object'
    );

    my $badmask = pdl( [ [ 0, 0, 1 ], [ 0, 1, 0 ] ] );
    my $p2 = PDL::SV->new( [ [qw(foo bar baz)], [qw(qux quux quuz)] ] )
      ->setbadif($badmask);

    pdl_is(
        $p2->match_regexp(qr/fo|ux/),
        pdl( [ [ 1, 0, 0 ], [ 1, 1, 0 ] ] )->setbadif($badmask),
        'ND object'
    );
};

subtest equal => sub {
    my $p1 = PDL::SV->new( [qw(foo bar baz)] )->setbadat(1);

    pdl_is( ( $p1 == $p1->copy ), pdl( [ 1, 1, 1 ] )->setbadat(1), '==' );
    pdl_is( ( $p1 eq $p1->copy ), pdl( [ 1, 1, 1 ] )->setbadat(1), 'eq' );

    my $badmask = pdl( [ [ 0, 0, 1 ], [ 0, 1, 0 ] ] );
    my $p2 = PDL::SV->new( [ [qw(foo bar baz)], [qw(qux quux quuz)] ] )
      ->setbadif($badmask);
    my $p2a = PDL::SV->new( [ [qw(foo1 bar baz)], [qw(qux quux quuz)] ] )
      ->setbadif($badmask);
    pdl_is( ( $p2 == $p2a ),
        pdl( [ [ 0, 1, 1 ], [ 1, 1, 1 ] ] )->setbadif($badmask) );
};

done_testing;