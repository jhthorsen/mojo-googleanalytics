use Mojo::Base -strict;
use Mojo::GoogleAnalytics;
use Test::More;

plan skip_all => 'TEST_GA_FILE is not set' unless $ENV{TEST_GA_FILE};
plan skip_all => 'TEST_GA_ID is not set'   unless $ENV{TEST_GA_ID};

my $ga = Mojo::GoogleAnalytics->new($ENV{TEST_GA_FILE})->view_id($ENV{TEST_GA_ID});
my ($p, $q, $report);

# Blocking
ok $ga->get_report($q)->count > 1, 'got results';

# Promise
$q = {dimensions => 'ga:country', metrics => 'ga:pageviews', interval => ['7daysAgo'],
  order_by => ['ga:pageviews desc']};
$p = $ga->get_report_p($q)->then(sub { $report = shift })->wait;
ok $report->count > 1, 'got results';

done_testing;
