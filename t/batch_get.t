use Mojo::Base -strict;
use Mojo::GoogleAnalytics;
use Test::More;

plan skip_all => 'TEST_GA_FILE is not set' unless $ENV{TEST_GA_FILE};
plan skip_all => 'TEST_GA_ID is not set'   unless $ENV{TEST_GA_ID};

my $ga = Mojo::GoogleAnalytics->new($ENV{TEST_GA_FILE});
my $res;

for my $attr (qw(client_email client_id private_key)) {
  ok $ga->$attr, "$attr is set";
}

$res = $ga->batch_get(
  {
    viewId     => $ENV{TEST_GA_ID},
    dimensions => [{name => 'ga:browser'}, {name => 'ga:country'}],
    pageSize   => 10,
    metrics    => [{expression => 'ga:pageviews'}, {expression => 'ga:sessions'}],
    metricFilterClauses =>
      [{filters => [{metricName => 'ga:pageviews', operator => 'GREATER_THAN', comparisonValue => '2'}]}]
  }
);

ok $res, 'got response';

done_testing;
