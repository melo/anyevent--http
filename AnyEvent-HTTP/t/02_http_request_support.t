use strict;
use warnings;
use Test::More 'no_plan';

use AnyEvent::Impl::Perl;
use AnyEvent::HTTP;
use HTTP::Request::Common qw( GET POST );

my $cv = AnyEvent->condvar;
my $req = GET("http://nonexistant.invalid/");
ok($req);

AnyEvent::HTTP::http_request($req, timeout => 1, sub {
   pass('callback called');
   $cv->send;
});

$cv->recv;
pass('completed GET');

$cv = AnyEvent->condvar;
$req = POST(
   "http://nonexistant.invalid",
   Content_Type => 'form-data',
   Content => [
      field1 => 'one beer',
      field2 => 'two beers',
   ],
);
ok($req);

AnyEvent::HTTP::http_request($req, timeout => 1, sub {
   pass('callback called');
   $cv->send;
});

$cv->recv;
pass('Completed POST');
