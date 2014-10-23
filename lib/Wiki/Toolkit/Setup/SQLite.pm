package Wiki::Toolkit::Setup::SQLite;

use strict;

use vars qw( @ISA $VERSION );

use Wiki::Toolkit::Setup::Database;

@ISA = qw( Wiki::Toolkit::Setup::Database );
$VERSION = '0.09';

use DBI;
use Carp;

my %create_sql = (
	schema_info => "
CREATE TABLE schema_info (
  version   integer      NOT NULL default 0
);
",

    node => "
CREATE TABLE node (
  id        integer      NOT NULL PRIMARY KEY AUTOINCREMENT,
  name      varchar(200) NOT NULL DEFAULT '',
  version   integer      NOT NULL default 0,
  text      mediumtext   NOT NULL default '',
  modified  datetime     default NULL,
  moderate  boolean      NOT NULL default '0'
)
",
    content => "
CREATE TABLE content (
  node_id   integer      NOT NULL,
  version   integer      NOT NULL default 0,
  text      mediumtext   NOT NULL default '',
  modified  datetime     default NULL,
  comment   mediumtext   NOT NULL default '',
  moderated boolean      NOT NULL default '1',
  PRIMARY KEY (node_id, version)
)
",
    internal_links => "
CREATE TABLE internal_links (
  link_from varchar(200) NOT NULL default '',
  link_to   varchar(200) NOT NULL default '',
  PRIMARY KEY (link_from, link_to)
)
",
    metadata => "
CREATE TABLE metadata (
  node_id        integer      NOT NULL,
  version        integer      NOT NULL default 0,
  metadata_type  varchar(200) NOT NULL DEFAULT '',
  metadata_value mediumtext   NOT NULL DEFAULT ''
)
"
);

=head1 NAME

Wiki::Toolkit::Setup::SQLite - Set up tables for a Wiki::Toolkit store in a SQLite database.

=head1 SYNOPSIS

  use Wiki::Toolkit::Setup::SQLite;
  Wiki::Toolkit::Setup::MySQLite::setup($dbfile);

=head1 DESCRIPTION

Set up a SQLite database for use as a Wiki::Toolkit store.

=head1 FUNCIONS

=over 4

=item B<setup>

  use Wiki::Toolkit::Setup::SQLite;

  Wiki::Toolkit::Setup::SQLite::setup( $filename );

or

  Wiki::Toolkit::Setup::SQLite::setup( $dbh );

Takes one argument - B<either> the name of the file that the SQLite
database is stored in B<or> an active database handle.

B<NOTE:> If a table that the module wants to create already exists,
C<setup> will leave it alone. This means that you can safely run this
on an existing L<Wiki::Toolkit> database to bring the schema up to date
with the current L<Wiki::Toolkit> version. If you wish to completely start
again with a fresh database, run C<cleardb> first.

=cut

sub setup {
    my @args = @_;
    my $dbh = _get_dbh( @args );
    my $disconnect_required = _disconnect_required( @args );

    # Check whether tables exist, set them up if not.
    my %tables = fetch_tables_listing($dbh);

	# Do we need to upgrade the schema?
	# (Don't check if no tables currently exist)
	my $upgrade_schema;
	my @cur_data; 
	if(scalar keys %tables > 0) {
		$upgrade_schema = Wiki::Toolkit::Setup::Database::get_database_upgrade_required($dbh,$VERSION);
	}
	if($upgrade_schema) {
		# Grab current data
		print "Upgrading: $upgrade_schema\n";
		@cur_data = eval("&Wiki::Toolkit::Setup::Database::fetch_upgrade_".$upgrade_schema."(\$dbh)");

		# Drop the current tables
		cleardb($dbh);

		# Grab new list of tables
		%tables = fetch_tables_listing($dbh);
	}

	# Set up tables if not found
    foreach my $required ( keys %create_sql ) {
        if ( $tables{$required} ) {
            print "Table $required already exists... skipping...\n";
        } else {
            print "Creating table $required... done\n";
            $dbh->do($create_sql{$required}) or croak $dbh->errstr;
		}
    }

	# Schema version
	$dbh->do("DELETE FROM schema_info");
	$dbh->do("INSERT INTO schema_info VALUES (". ($VERSION*100) .")");

	# If upgrading, load in the new data
	if($upgrade_schema) {
		Wiki::Toolkit::Setup::Database::bulk_data_insert($dbh,@cur_data);
	}

    # Clean up if we made our own dbh.
    $dbh->disconnect if $disconnect_required;
}

# Internal method - what tables are defined?
sub fetch_tables_listing {
	my $dbh = shift;

    # Check whether tables exist, set them up if not.
    my $sql = "SELECT name FROM sqlite_master
               WHERE type='table' AND name in ("
            . join( ",", map { $dbh->quote($_) } keys %create_sql ) . ")";
    my $sth = $dbh->prepare($sql) or croak $dbh->errstr;
    $sth->execute;
    my %tables;
    while ( my $table = $sth->fetchrow_array ) {
        $tables{$table} = 1;
    }
	return %tables;
}

=item B<cleardb>

  use Wiki::Toolkit::Setup::SQLite;

  # Clear out all Wiki::Toolkit tables from the database.
  Wiki::Toolkit::Setup::SQLite::cleardb( $filename );

or

  Wiki::Toolkit::Setup::SQLite::cleardb( $dbh );

Takes one argument - B<either> the name of the file that the SQLite
database is stored in B<or> an active database handle.

Clears out all L<Wiki::Toolkit> store tables from the database. B<NOTE>
that this will lose all your data; you probably only want to use this
for testing purposes or if you really screwed up somewhere. Note also
that it doesn't touch any L<Wiki::Toolkit> search backend tables; if you
have any of those in the same or a different database see
L<Wiki::Toolkit::Setup::DBIxFTS> or L<Wiki::Toolkit::Setup::SII>, depending on
which search backend you're using.

=cut

sub cleardb {
    my @args = @_;
    my $dbh = _get_dbh( @args );
    my $disconnect_required = _disconnect_required( @args );

    print "Dropping tables... ";
    my $sql = "SELECT name FROM sqlite_master
               WHERE type='table' AND name in ("
            . join( ",", map { $dbh->quote($_) } keys %create_sql ) . ")";
    foreach my $tableref (@{$dbh->selectall_arrayref($sql)}) {
        $dbh->do("DROP TABLE $tableref->[0]") or croak $dbh->errstr;
    }
    print "done\n";

    # Clean up if we made our own dbh.
    $dbh->disconnect if $disconnect_required;
}

sub _get_dbh {
    # Database handle passed in.
    if ( ref $_[0] and ref $_[0] eq 'DBI::db' ) {
        return $_[0];
    }

    # Args passed as hashref.
    if ( ref $_[0] and ref $_[0] eq 'HASH' ) {
        my %args = %{$_[0]};
        if ( $args{dbh} ) {
            return $args{dbh};
	} else {
            return _make_dbh( %args );
        }
    }

    # Args passed as list of connection details.
    return _make_dbh( dbname => $_[0] );
}

sub _disconnect_required {
    # Database handle passed in.
    if ( ref $_[0] and ref $_[0] eq 'DBI::db' ) {
        return 0;
    }

    # Args passed as hashref.
    if ( ref $_[0] and ref $_[0] eq 'HASH' ) {
        my %args = %{$_[0]};
        if ( $args{dbh} ) {
            return 0;
	} else {
            return 1;
        }
    }

    # Args passed as list of connection details.
    return 1;
}

sub _make_dbh {
    my %args = @_;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$args{dbname}", "", "",
			   { PrintError => 1, RaiseError => 1,
			     AutoCommit => 1 } )
      or croak DBI::errstr;
    return $dbh;
}

=back

=head1 ALTERNATIVE CALLING SYNTAX

As requested by Podmaster.  Instead of passing arguments to the methods as

  ($filename)

you can pass them as

  ( { dbname => $filename } )

or indeed

  ( { dbh => $dbh } )

Note that's a hashref, not a hash.

=head1 AUTHOR

Kake Pugh (kake@earth.li).

=head1 COPYRIGHT

     Copyright (C) 2002-2004 Kake Pugh.  All Rights Reserved.
     Copyright (C) 2006 the Wiki::Toolkit team. All Rights Reserved.

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

L<Wiki::Toolkit>, L<Wiki::Toolkit::Setup::DBIxFTS>, L<Wiki::Toolkit::Setup::SII>

=cut

1;

