package Mojo::GoogleAnalytics;
use Mojo::Base -base;

use Mojo::Collection;
use Mojo::File 'path';
use Mojo::GoogleAnalytics::Report;
use Mojo::JSON qw(decode_json);
use Mojo::JWT;
use Mojo::UserAgent;

our $VERSION = '0.01';

use constant DEBUG => $ENV{MOJO_GA_DEBUG} || 0;

has authorization => sub { +{} };
has client_email  => sub { Carp::confess('client_email is required') };
has client_id     => sub { Carp::confess('client_id is required') };
has private_key   => sub { Carp::confess('private_key is required') };
has ua            => sub { Mojo::UserAgent->new(max_redirects => 3) };

sub authorize {
  my ($self, $cb) = @_;
  my $prev = $self->authorization;
  my $time = time;
  my ($jwt, @ua_args);

  warn "[RG::Google] Authorization exp: @{[$prev->{exp} ? $prev->{exp} : -1]} < $time\n" if DEBUG;

  if ($prev->{exp} and $time < $prev->{exp}) {
    $self->$cb('') if $cb;
    return $self;
  }

  $ua_args[0] = Mojo::URL->new($self->{token_uri});
  $jwt = Mojo::JWT->new->algorithm('RS256')->secret($self->private_key);

  $jwt->claims(
    {
      aud   => $ua_args[0]->to_string,
      exp   => $time + 3600,
      iat   => $time,
      iss   => $self->client_email,
      scope => $self->{auth_scope},
    }
  );

  push @ua_args, (form => {grant_type => 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion => $jwt->encode});
  warn "[RG::Google] Authenticating with $ua_args[0] ...\n", if DEBUG;

  if ($cb) {
    Mojo::IOLoop->delay(
      sub { $self->ua->post(@ua_args, shift->begin) },
      sub { $self->$cb($self->_process_authorize_response(pop)) },
    );
  }
  else {
    my ($err, $res) = $self->_process_authorize_response($self->ua->post(@ua_args));
    die $err if $err;
  }

  return $self;
}

sub batch_get {
  my ($self, $query, $cb) = @_;
  my @ua_args;

  @ua_args = (Mojo::URL->new($self->{batch_get_uri}), {},
    json => {reportRequests => ref $query eq 'ARRAY' ? $query : [$query]});

  if ($cb) {
    Mojo::IOLoop->delay(
      sub { $self->authorize(shift->begin) },
      sub {
        my ($delay, $err) = @_;
        return $self->$cb($err, {}) if $err;
        warn "[RG::Google] Getting analytics data from $ua_args[0] ...\n", if DEBUG;
        $ua_args[1] = {Authorization => $self->authorization->{header}};
        $self->ua->post(@ua_args, $delay->begin);
      },
      sub { $self->$cb($self->_process_batch_get_response($query, pop)) }
    );
    return $self;
  }
  else {
    $ua_args[1] = {Authorization => $self->authorize->authorization->{header}};
    warn "[RG::Google] Getting analytics data from $ua_args[0] ...\n", if DEBUG;
    my ($err, $res) = $self->_process_batch_get_response($query, $self->ua->post(@ua_args));
    die $err->{message} if $err;
    return $res;
  }
}

sub from_file {
  my ($self, $file) = @_;
  my $attrs = decode_json(path($file)->slurp);

  for my $attr (keys %$attrs) {
    $self->{$attr} ||= $attrs->{$attr};
    warn qq([Mojo::GoogleAnalytics] Read "$attr" from $file\n) if DEBUG;
  }

  return $self;
}

sub new {
  my $class = shift;
  _defaults(@_ == 1 ? $class->SUPER::new->from_file(shift) : $class->SUPER::new(@_));
}

sub _defaults {
  $_[0]->{token_uri}     ||= 'https://accounts.google.com/o/oauth2/token';
  $_[0]->{auth_scope}    ||= 'https://www.googleapis.com/auth/analytics.readonly';
  $_[0]->{batch_get_uri} ||= 'https://analyticsreporting.googleapis.com/v4/reports:batchGet';
  $_[0];
}

sub _process_authorize_response {
  my ($self, $tx) = @_;
  my $err = $tx->error;
  my $res = $tx->res->json;
  my $url = $tx->req->url;

  if ($err) {
    $err = sprintf '%s >>> %s (%s)', $url, $res->{error_description} || $err->{message} || 'Unknown error',
      $err->{code} || 0;
    warn "[RG::Google] $err\n", if DEBUG;
  }
  else {
    warn "[RG::Google] Authenticated with $url\n", if DEBUG;
    $self->authorization(
      {exp => time + ($res->{expires_in} - 600), header => "$res->{token_type} $res->{access_token}"});
  }

  return $err // '';
}

sub _process_batch_get_response {
  my ($self, $query, $tx) = @_;
  my $as_list = ref $query eq 'ARRAY';
  my $url     = $tx->req->url;
  my $res     = $tx->res->json || {};
  my $err     = $res->{error} || $tx->error;
  my $reports = $res->{reports} || ($as_list ? $query : [{}]);

  @$reports = map {
    $_->{error} = $err;
    $_->{query} = $as_list ? shift @$query : $query, $_->{tx} = $tx;
    Mojo::GoogleAnalytics::Report->new($_);
  } @$reports;

  if ($err) {
    $err = sprintf '%s >>> %s (%s)', $url, $err->{message} || 'Unknown error', $err->{code} || 0;
  }

  return $err || '', $as_list ? Mojo::Collection->new(@$reports) : $reports->[0];
}

1;

=encoding utf8

=head1 NAME

Mojo::GoogleAnalytics - Extract data from Google Analytics using Mojo UserAgent

=head1 SYNOPSIS

  my $ga     = Mojo::GoogleAnalytics->new("/path/to/credentials.json");
  my $report = $ga->batch_get({
    viewId     => "ga:152749100",
    dateRanges => [{startDate => "7daysAgo", endDate => "1daysAgo"}],
    dimensions => [{name => "ga:country"}, {name => "ga:browser"}],
    metrics    => [{expression => "ga:pageviews"}, {expression => "ga:sessions"}],
    orderBys   => [{fieldName => "ga:pageviews", sortOrder => "DESCENDING"}],
    pageSize   => 10,
  });

  print $report->rows_to_table(as => "text");

=head1 DESCRIPTION

L<Mojo::GoogleAnalytics> is a Google Analytics client which allow you to
extract data non-blocking.

This module is work in progress and currently EXPERIMENTAL. Let me know if you
start using it or has any feedback regarding the API.

=head1 ATTRIBUTES

=head2 authorization

  $hash_ref = $self->authorization;

Holds authorization data, extracted by L</authorize>. This can be useful to set
from a cache if L<Mojo::GoogleAnalytics> objects are created and destroyed
frequently, but with the same credentials.

=head2 client_email

  $str = $self->client_email;

Example: "some-app@some-project.iam.gserviceaccount.com".

=head2 client_id

  $str = $self->client_id;

Example: "103742165385019792511".

=head2 private_key

  $str = $self->private_key;

Holds the content of a pem file that looks like this:

  -----BEGIN PRIVATE KEY-----
  ...
  ...
  -----END PRIVATE KEY-----

=head2 ua

  $ua = $self->ua;
  $self = $self->ua(Mojo::UserAgent->new);

Holds a L<Mojo::UserAgent> object.

=head1 METHODS

=head2 authorize

  $self = $self->authorize;
  $self = $self->authorize(sub { my ($self, $err) = @_; });

This method will set L</authorization>. Note that this method is automatically
called from inside of L</batch_get>, unless already authorized.

=head2 batch_get

  $report = $self->batch_get($query);
  $self = $self->batch_get($query, sub { my ($self, $err, $report) = @_ });

Used to extract data from Google Analytics. C<$report> will be a
L<Mojo::Collection> if C<$query> is an array ref, and a single
L<Mojo::GoogleAnalytics::Report> object if C<$query> is a hash.

C<$err> is a string on error and false value on success.

=head2 from_file

  $self = $self->from_file("/path/to/credentials.json");

Used to load attributes from a JSON credentials file, generated from
L<https://console.developers.google.com/apis/credentials>. Example file:

  {
    "type": "service_account",
    "project_id": "cool-project-238176",
    "private_key_id": "01234abc6780dc2a3284851423099daaad8cff92",
    "private_key": "-----BEGIN PRIVATE KEY-----...\n-----END PRIVATE KEY-----\n",
    "client_email": "some-name@cool-project-238176.iam.gserviceaccount.com",
    "client_id": "103742165385019792511",
    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
    "token_uri": "https://accounts.google.com/o/oauth2/token",
  }

Note: The JSON credentials file will probably contain more fields than is
listed above.

=head2 new

  $self = Mojo::GoogleAnalytics->new(%attrs);
  $self = Mojo::GoogleAnalytics->new(\%attrs);
  $self = Mojo::GoogleAnalytics->new("/path/to/credentials.json");

Used to construct a new L<Mojo::GoogleAnalytics> object. Calling C<new()> with
a single argument will cause L</from_file> to be called with that argument.

=head1 AUTHOR

Jan Henning Thorsen

=head1 COPYRIGHT AND LICENSE

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut
