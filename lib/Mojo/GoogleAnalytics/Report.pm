package Mojo::GoogleAnalytics::Report;
use Mojo::Base -base;

sub count      { shift->{data}{rowCount} || 0 }
sub error      { shift->{error} }
sub page_token { shift->{nextPageToken}  || '' }
sub query      { shift->{query}          || {} }
sub rows       { shift->{data}{rows}     || [] }
sub tx         { shift->{tx} }

has maximums => sub { shift->_stats('maximums') };
has minimums => sub { shift->_stats('minimums') };
has totals   => sub { shift->_stats('totals') };

sub rows_to_hash {
  my $self    = shift;
  my $headers = $self->{columnHeader}{metricHeader}{metricHeaderEntries};
  my $reduced = {};

  for my $row (@{$self->rows}) {
    my $level   = $reduced;
    my $metrics = $row->{metrics}[0]{values};
    my $prev;

    for my $dimension (@{$row->{dimensions}}) {
      $prev = $level;
      $level = $level->{$dimension} ||= {};
    }

    if (@$metrics == 1) {
      $prev->{$row->{dimensions}[-1]} = $metrics->[0];
    }
    else {
      for my $i (0 .. @$headers - 1) {
        $level->{$headers->[$i]{name}} = $metrics->[$i];
      }
    }
  }

  return $reduced;
}

sub rows_to_table {
  my ($self, %args) = @_;
  my $headers = $self->{columnHeader};
  my @rows;

  unless ($args{no_headers}) {
    push @rows, [@{$headers->{dimensions}}, map { $_->{name} } @{$headers->{metricHeader}{metricHeaderEntries}}];
  }

  for my $row (@{$self->rows}) {
    push @rows, [@{$row->{dimensions}}, @{$row->{metrics}[0]{values}}];
  }

  if (($args{as} || '') eq 'text') {
    return Mojo::Util::tablify(\@rows);
  }

  return \@rows;
}

sub _stats {
  my ($self, $attr) = @_;
  my $headers = $self->{columnHeader}{metricHeader}{metricHeaderEntries};
  my $metrics = delete $self->{data}{$attr};
  my %data;

  $metrics = $metrics->[0]{values};

  for my $i (0 .. @$headers - 1) {
    $data{$headers->[$i]{name}} = $metrics->[$i];
  }

  return \%data;
}

1;
