use strict;
use warnings;
use Test::More;

use AnyEvent::Impl::Perl;
use AnyEvent::HTTP;

eval {
  require HTTP::Request::Common;
  HTTP::Request::Common->import(qw( GET POST ));
};
plan skip_all => 'This test depends on HTTP::Request::Common'
  if $@;

plan tests => 6;

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
