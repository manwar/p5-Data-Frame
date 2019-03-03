requires "Carp" => "0";
requires "Class::Method::Modifiers" => "0";
requires "Data::Dumper" => "0";
requires "Data::Munge" => "0";
requires "Data::Perl" => "0";
requires "Data::Perl::Collection::Array" => "0";
requires "Data::Rmap" => "0";
requires "Devel::OverloadInfo" => "0";
requires "Eval::Quosure" => "0.001";
requires "Exporter" => "0";
requires "Exporter::Tiny" => "0";
requires "File::ShareDir" => "0";
requires "Function::Parameters" => "2.0";
requires "Import::Into" => "0";
requires "List::AllUtils" => "0";
requires "List::MoreUtils" => "0.423";
requires "Module::Load" => "0";
requires "Module::Runtime" => "0";
requires "Moo" => "2.003004";
requires "Moo::Role" => "0";
requires "MooX::Traits" => "0";
requires "Moose::Autobox" => "0";
requires "Moose::Role" => "0";
requires "PDL" => "2.007";
requires "PDL::Basic" => "0";
requires "PDL::Core" => "0";
requires "PDL::DateTime" => "0";
requires "PDL::Lite" => "0";
requires "PDL::Primitive" => "0";
requires "PDL::Types" => "0";
requires "POSIX" => "0";
requires "Package::Stash" => "0";
requires "Path::Tiny" => "0";
requires "Ref::Util" => "0";
requires "Role::Tiny" => "0";
requires "Role::Tiny::With" => "0";
requires "Safe::Isa" => "1.000009";
requires "Scalar::Util" => "0";
requires "Sereal::Decoder" => "0";
requires "Sereal::Encoder" => "0";
requires "Storable" => "0";
requires "Syntax::Keyword::Try" => "0";
requires "Test2::API" => "0";
requires "Test2::Util::Ref" => "0";
requires "Test2::Util::Table" => "0";
requires "Test::Deep::NoTest" => "0";
requires "Text::CSV" => "0";
requires "Text::Table::Tiny" => "0";
requires "Try::Tiny" => "0";
requires "Type::Library" => "0";
requires "Type::Params" => "0";
requires "Type::Tiny" => "1.004004";
requires "Type::Utils" => "0";
requires "Types::PDL" => "0";
requires "Types::Standard" => "0";
requires "boolean" => "0";
requires "failures" => "0";
requires "feature" => "0";
requires "namespace::autoclean" => "0.28";
requires "overload" => "0";
requires "parent" => "0";
requires "perl" => "5.016";
requires "strict" => "0";
requires "utf8" => "0";
requires "warnings" => "0";

on 'test' => sub {
  requires "FindBin" => "0";
  requires "Math::BigInt" => "0";
  requires "Test2::Tools::PDL" => "0";
  requires "Test2::Tools::Warnings" => "0";
  requires "Test2::V0" => "0";
  requires "Test::Fatal" => "0";
  requires "Test::More" => "0";
  requires "Test::Most" => "0";
};

on 'configure' => sub {
  requires "ExtUtils::MakeMaker" => "0";
  requires "File::ShareDir::Install" => "0.06";
};

on 'develop' => sub {
  requires "Test::Pod" => "1.41";
};
