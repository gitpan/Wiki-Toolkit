package Wiki::Toolkit::Search::Lucy;

use strict;

use Lucy::Analysis::PolyAnalyzer;
use Lucy::Index::Indexer;
use Lucy::Index::PolyReader;
use Lucy::Plan::FullTextType;
use Lucy::Plan::Schema;
use Lucy::Search::IndexSearcher;
use Lucy::Search::QueryParser;

use vars qw( @ISA $VERSION );

$VERSION = '0.02';
use base 'Wiki::Toolkit::Search::Base';

=head1 NAME

Wiki::Toolkit::Search::Lucy - Use Lucy to search your Wiki::Toolkit wiki.

=head1 SYNOPSIS

  my $search = Wiki::Toolkit::Search::Lucy->new( path => "/var/lucy/wiki" );
  my %wombat_nodes = $search->search_nodes( "wombat" );

Provides L<Lucy>-based search methods for L<Wiki::Toolkit>.

=cut

=head1 METHODS

=over 4

=item B<new>

  my $search = Wiki::Toolkit::Search::Lucy->new( path => "/var/lucy/wiki" );

Takes only one parameter, which is mandatory. C<path> must be a directory
for storing the indexed data.  It should exist and be writeable.

=cut

sub _init {
    my ( $self, %args ) = @_;

    # Set up the Lucy schema.  Content and fuzzy title will be indexed but
    # not stored (since we don't need to retrieve them).
    my $schema = Lucy::Plan::Schema->new;
    my $polyanalyzer = Lucy::Analysis::PolyAnalyzer->new( language => "en" );
    my $stored_type = Lucy::Plan::FullTextType->new(
                          analyzer => $polyanalyzer );
    my $unstored_type = Lucy::Plan::FullTextType->new(
                          analyzer => $polyanalyzer, stored => 0 );
    $schema->spec_field( name => "content", type => $unstored_type );
    $schema->spec_field( name => "fuzzy",   type => $unstored_type );
    $schema->spec_field( name => "title",   type => $stored_type );

    $self->{_schema} = $schema;
    $self->{_dir} = $args{path};
    return $self;
}

sub _dir { shift->{_dir} }
sub _schema { shift->{_schema} }

=item B<index_node>

  $search->index_node( $node, $content );

Indexes or reindexes the given node in the search engine indexes. 
You must supply both the node name and its content.

=cut

sub index_node {
    my ( $self, $node, $content ) = @_;

    # Delete the old version.
    $self->_delete_node( $node );

    my $indexer = Lucy::Index::Indexer->new(
        index    => $self->_dir,
        schema   => $self->_schema,
        create   => 1,
        truncate => 0,
    );

    my $fuzzy = $self->canonicalise_title( $node );
    $indexer->add_doc( {
        content => join( " ", $node, $content ),
        fuzzy   => $fuzzy,
        title   => $node,
    } );
    $indexer->commit;
}

sub _delete_node {
    my ( $self, $node ) = @_;

    my $indexer = Lucy::Index::Indexer->new(
        index    => $self->_dir,
        schema   => $self->_schema,
        create   => 1,
        truncate => 0,
    );
    $indexer->delete_by_term( field => "title", term => $node );
    $indexer->commit;
}

=item B<search_nodes>

  # Find all the nodes which contain the word 'expert'.
  my %results = $search->search_nodes( "expert" );

Returns a (possibly empty) hash whose keys are the node names and
whose values are the scores.

Defaults to AND searches (if C<$and_or> is not supplied, or is anything
other than C<OR> or C<or>).

Searches are case-insensitive.

=cut

sub search_nodes {
    my ( $self, $searchstring, $and_or ) = @_;

    # Bail and return empty list if nothing stored.
    return () unless $self->_index_exists;

    $and_or = uc( $and_or || "" );
    $and_or = "AND" unless $and_or eq "OR";

    my $queryparser = Lucy::Search::QueryParser->new(
        schema         => $self->_schema,
        default_boolop => $and_or,
    );

    my $query = $queryparser->parse( $searchstring );

    my $searcher = Lucy::Search::IndexSearcher->new(
        index => $self->_dir,
    );

    my $num_docs = $searcher->doc_max();
    my $hits = $searcher->hits(
        query      => $query,
        num_wanted => $num_docs,
    );

    my %results;
    while ( my $hit = $hits->next ) {
        $results{ $hit->{title} } = $hit->get_score;
    }
    return %results;
}

# Fuzzy title search - exact match has highest score.
sub _fuzzy_match {
    my ( $self, $string, $canonical ) = @_;

    # Bail and return empty list if nothing stored.
    return () unless $self->_index_exists;

    my $queryparser = Lucy::Search::QueryParser->new(
        schema         => $self->_schema,
        default_boolop => "AND",
    );

    my $query = $queryparser->parse( $canonical );

    my $searcher = Lucy::Search::IndexSearcher->new(
        index => $self->_dir,
    );

    my $num_docs = $searcher->doc_max();
    my $hits = $searcher->hits(
        query      => $query,
        num_wanted => $num_docs,
    );

    my %results;
    while ( my $hit = $hits->next ) {
        $results{ $hit->{title} } = $hit->get_score;
    }
    return map { $_ => ($_ eq $string ? 2 : 1) } keys %results;
}

# Returns true if and only if we have data stored.
sub _index_exists {
    my $self = shift;
    my $reader = Lucy::Index::PolyReader->open( index => $self->_dir );
    return @{ $reader->seg_readers };
}

sub supports_fuzzy_searches { 1; }
sub supports_phrase_searches { 1; }

=back

=head1 SEE ALSO

L<Wiki::Toolkit>, L<Wiki::Toolkit::Search::Base>.

=cut

1;
