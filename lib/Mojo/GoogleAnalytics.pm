package Mojo::GoogleAnalytics;
use Mojo::Base -base;

use Mojo::File 'path';
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
      sub { $self->$cb($self->_process_batch_get_response(pop)) }
    );
    return $self;
  }
  else {
    $ua_args[1] = {Authorization => $self->authorize->authorization->{header}};
    warn "[RG::Google] Getting analytics data from $ua_args[0] ...\n", if DEBUG;
    my ($err, $res) = $self->_process_batch_get_response($self->ua->post(@ua_args));
    die $err if $err;
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
  my ($self, $tx) = @_;
  my $url = $tx->req->url;
  my $res = $tx->res->json || {};
  my $err = $res->{error} || $tx->error;

  if ($err) {
    $err = sprintf '%s >>> %s (%s)', $url, $err->{message} || 'Unknown error', $err->{code} || 0;
  }

  warn "[RG::Google] $err\n", if DEBUG and $err;
  return $err || '', $res;
}

1;
