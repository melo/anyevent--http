=head1 NAME

AnyEvent::HTTP - simple but non-blocking HTTP/HTTPS client

=head1 SYNOPSIS

   use AnyEvent::HTTP;

   http_get "http://www.nethype.de/", sub { print $_[1] };

   # ... do something else here

=head1 DESCRIPTION

This module is an L<AnyEvent> user, you need to make sure that you use and
run a supported event loop.

This module implements a simple, stateless and non-blocking HTTP
client. It supports GET, POST and other request methods, cookies and more,
all on a very low level. It can follow redirects supports proxies and
automatically limits the number of connections to the values specified in
the RFC.

It should generally be a "good client" that is enough for most HTTP
tasks. Simple tasks should be simple, but complex tasks should still be
possible as the user retains control over request and response headers.

The caller is responsible for authentication management, cookies (if
the simplistic implementation in this module doesn't suffice), referer
and other high-level protocol details for which this module offers only
limited support.

=head2 METHODS

=over 4

=cut

package AnyEvent::HTTP;

use strict;
no warnings;

use Carp;

use AnyEvent ();
use AnyEvent::Util ();
use AnyEvent::Socket ();
use AnyEvent::Handle ();
use Scalar::Util qw( blessed );

use base Exporter::;

our $VERSION = '1.02';

our @EXPORT = qw(http_get http_post http_head http_request);

our $USERAGENT          = "Mozilla/5.0 (compatible; AnyEvent::HTTP/$VERSION; +http://software.schmorp.de/pkg/AnyEvent)";
our $MAX_RECURSE        =  10;
our $MAX_PERSISTENT     =   8;
our $PERSISTENT_TIMEOUT =   2;
our $TIMEOUT            = 300;

# changing these is evil
our $MAX_PERSISTENT_PER_HOST = 2;
our $MAX_PER_HOST       = 4;

our $PROXY;
our $ACTIVE = 0;

my %KA_COUNT; # number of open keep-alive connections per host
my %CO_SLOT;  # number of open connections, and wait queue, per host

=item http_get $url, key => value..., $cb->($data, $headers)

Executes an HTTP-GET request. See the http_request function for details on
additional parameters.

=item http_head $url, key => value..., $cb->($data, $headers)

Executes an HTTP-HEAD request. See the http_request function for details on
additional parameters.

=item http_post $url, $body, key => value..., $cb->($data, $headers)

Executes an HTTP-POST request with a request body of C<$bod>. See the
http_request function for details on additional parameters.

=item http_request $method => $url, key => value..., $cb->($data, $headers)
=item http_request $obj, key => value..., $cb->($data, $headers)

Executes a HTTP request of type C<$method> (e.g. C<GET>, C<POST>). The URL
must be an absolute http or https URL.

Alternatively, you can provide an object that implements the same interface
as L<HTTP::Request>. The object will be used to obtain the method and URL.
If it contains a non-empty request body, this will be used as well. The
headers will be merged.

The callback will be called with the response data as first argument
(or C<undef> if it wasn't available due to errors), and a hash-ref with
response headers as second argument.

All the headers in that hash are lowercased. In addition to the response
headers, the "pseudo-headers" C<HTTPVersion>, C<Status> and C<Reason>
contain the three parts of the HTTP Status-Line of the same name. The
pseudo-header C<URL> contains the original URL (which can differ from the
requested URL when following redirects).

If the server sends a header multiple lines, then their contents will be
joined together with C<\x00>.

If an internal error occurs, such as not being able to resolve a hostname,
then C<$data> will be C<undef>, C<< $headers->{Status} >> will be C<599>
and the C<Reason> pseudo-header will contain an error message.

A typical callback might look like this:

   sub {
      my ($body, $hdr) = @_;

      if ($hdr->{Status} =~ /^2/) {
         ... everything should be ok
      } else {
         print "error, $hdr->{Status} $hdr->{Reason}\n";
      }
   }

Additional parameters are key-value pairs, and are fully optional. They
include:

=over 4

=item recurse => $count (default: $MAX_RECURSE)

Whether to recurse requests or not, e.g. on redirects, authentication
retries and so on, and how often to do so.

=item headers => hashref

The request headers to use. Currently, C<http_request> may provide its
own C<Host:>, C<Content-Length:>, C<Connection:> and C<Cookie:> headers
and will provide defaults for C<User-Agent:> and C<Referer:>.

=item timeout => $seconds

The time-out to use for various stages - each connect attempt will reset
the timeout, as will read or write activity. Default timeout is 5 minutes.

=item proxy => [$host, $port[, $scheme]] or undef

Use the given http proxy for all requests. If not specified, then the
default proxy (as specified by C<$ENV{http_proxy}>) is used.

C<$scheme> must be either missing or C<http> for HTTP, or C<https> for
HTTPS.

=item body => $string

The request body, usually empty. Will be-sent as-is (future versions of
this module might offer more options).

=item cookie_jar => $hash_ref

Passing this parameter enables (simplified) cookie-processing, loosely
based on the original netscape specification.

The C<$hash_ref> must be an (initially empty) hash reference which will
get updated automatically. It is possible to save the cookie_jar to
persistent storage with something like JSON or Storable, but this is not
recommended, as expire times are currently being ignored.

Note that this cookie implementation is not of very high quality, nor
meant to be complete. If you want complete cookie management you have to
do that on your own. C<cookie_jar> is meant as a quick fix to get some
cookie-using sites working. Cookies are a privacy disaster, do not use
them unless required to.

=back

Example: make a simple HTTP GET request for http://www.nethype.de/

   http_request GET => "http://www.nethype.de/", sub {
      my ($body, $hdr) = @_;
      print "$body\n";
   };

Example: make a HTTP HEAD request on https://www.google.com/, use a
timeout of 30 seconds.

   http_request
      GET     => "https://www.google.com",
      timeout => 30,
      sub {
         my ($body, $hdr) = @_;
         use Data::Dumper;
         print Dumper $hdr;
      }
   ;

=cut

sub _slot_schedule;
sub _slot_schedule($) {
   my $host = shift;

   while ($CO_SLOT{$host}[0] < $MAX_PER_HOST) {
      if (my $cb = shift @{ $CO_SLOT{$host}[1] }) {
         # somebody wants that slot
         ++$CO_SLOT{$host}[0];
         ++$ACTIVE;

         $cb->(AnyEvent::Util::guard {
            --$ACTIVE;
            --$CO_SLOT{$host}[0];
            _slot_schedule $host;
         });
      } else {
         # nobody wants the slot, maybe we can forget about it
         delete $CO_SLOT{$host} unless $CO_SLOT{$host}[0];
         last;
      }
   }
}

# wait for a free slot on host, call callback
sub _get_slot($$) {
   push @{ $CO_SLOT{$_[0]}[1] }, $_[1];

   _slot_schedule $_[0];
}

sub http_request($$@) {
   my $cb = pop;
   my $method = shift;
   my ($url, %arg);
   
   # First parameter can be HTTP::Request
   if (blessed($method)) {
     my $req = $method;
     $method = $req->method;
     $url    = $req->url->as_string;

     %arg    = @_;
     $arg{body} = $req->content if length($req->content || '');
     
     # Override headers
     my $headers = $arg{headers} ||= {};
     foreach my $name ($req->headers->header_field_names) {
       $headers->{lc($name)} = $req->header($name);
     }
   }
   else {
     ($url, %arg) = @_;
   }
   
   my %hdr;

   $method = uc $method;

   if (my $hdr = $arg{headers}) {
      while (my ($k, $v) = each %$hdr) {
         $hdr{lc $k} = $v;
      }
   }

   my $recurse = exists $arg{recurse} ? $arg{recurse} : $MAX_RECURSE;

   return $cb->(undef, { Status => 599, Reason => "recursion limit reached", URL => $url })
      if $recurse < 0;

   my $proxy   = $arg{proxy}   || $PROXY;
   my $timeout = $arg{timeout} || $TIMEOUT;

   $hdr{"user-agent"} ||= $USERAGENT;

   my ($scheme, $authority, $upath, $query, $fragment) =
      $url =~ m|(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?|;

   $scheme = lc $scheme;

   my $uport = $scheme eq "http"  ?  80
             : $scheme eq "https" ? 443
             : return $cb->(undef, { Status => 599, Reason => "only http and https URL schemes supported", URL => $url });

   $hdr{referer} ||= "$scheme://$authority$upath"; # leave out fragment and query string, just a heuristic

   $authority =~ /^(?: .*\@ )? ([^\@:]+) (?: : (\d+) )?$/x
      or return $cb->(undef, { Status => 599, Reason => "unparsable URL", URL => $url });

   my $uhost = $1;
   $uport = $2 if defined $2;

   $uhost =~ s/^\[(.*)\]$/$1/;
   $upath .= "?$query" if length $query;

   $upath =~ s%^/?%/%;

   # cookie processing
   if (my $jar = $arg{cookie_jar}) {
      %$jar = () if $jar->{version} < 1;
 
      my @cookie;
 
      while (my ($chost, $v) = each %$jar) {
         next unless $chost eq substr $uhost, -length $chost;
         next unless $chost =~ /^\./;
 
         while (my ($cpath, $v) = each %$v) {
            next unless $cpath eq substr $upath, 0, length $cpath;
 
            while (my ($k, $v) = each %$v) {
               next if $scheme ne "https" && exists $v->{secure};
               push @cookie, "$k=$v->{value}";
            }
         }
      }
 
      $hdr{cookie} = join "; ", @cookie
         if @cookie;
   }

   my ($rhost, $rport, $rpath); # request host, port, path

   if ($proxy) {
      ($rhost, $rport, $scheme) = @$proxy;
      $rpath = $url;
   } else {
      ($rhost, $rport, $rpath) = ($uhost, $uport, $upath);
      $hdr{host} = $uhost;
   }

   $hdr{"content-length"} = length $arg{body};

   my %state = (connect_guard => 1);

   _get_slot $uhost, sub {
      $state{slot_guard} = shift;

      return unless $state{connect_guard};

      $state{connect_guard} = AnyEvent::Socket::tcp_connect $rhost, $rport, sub {
         $state{fh} = shift
            or return $cb->(undef, { Status => 599, Reason => "$!", URL => $url });

         delete $state{connect_guard}; # reduce memory usage, save a tree

         # get handle
         $state{handle} = new AnyEvent::Handle
            fh => $state{fh},
            ($scheme eq "https" ? (tls => "connect") : ());

         # limit the number of persistent connections
         if ($KA_COUNT{$_[1]} < $MAX_PERSISTENT_PER_HOST) {
            ++$KA_COUNT{$_[1]};
            $state{handle}{ka_count_guard} = AnyEvent::Util::guard { --$KA_COUNT{$_[1]} };
            $hdr{connection} = "keep-alive";
            delete $hdr{connection}; # keep-alive not yet supported
         } else {
            delete $hdr{connection};
         }

         # (re-)configure handle
         $state{handle}->timeout ($timeout);
         $state{handle}->on_error (sub {
            my $errno = "$!";
            %state = ();
            $cb->(undef, { Status => 599, Reason => $errno, URL => $url });
         });
         $state{handle}->on_eof (sub {
            %state = ();
            $cb->(undef, { Status => 599, Reason => "unexpected end-of-file", URL => $url });
         });

         # send request
         $state{handle}->push_write (
            "$method $rpath HTTP/1.0\015\012"
            . (join "", map "$_: $hdr{$_}\015\012", keys %hdr)
            . "\015\012"
            . (delete $arg{body})
         );

         %hdr = (); # reduce memory usage, save a kitten

         # status line
         $state{handle}->push_read (line => qr/\015?\012/, sub {
            $_[1] =~ /^HTTP\/([0-9\.]+) \s+ ([0-9]{3}) \s+ ([^\015\012]+)/ix
               or return (%state = (), $cb->(undef, { Status => 599, Reason => "invalid server response ($_[1])", URL => $url }));

            my %hdr = ( # response headers
               HTTPVersion => "\x00$1",
               Status      => "\x00$2",
               Reason      => "\x00$3",
               URL         => "\x00$url"
            );

            # headers, could be optimized a bit
            $state{handle}->unshift_read (line => qr/\015?\012\015?\012/, sub {
               for ("$_[1]\012") {
                  # we support spaces in field names, as lotus domino
                  # creates them.
                  $hdr{lc $1} .= "\x00$2"
                     while /\G
                           ([^:\000-\037]+):
                           [\011\040]*
                           ((?: [^\015\012]+ | \015?\012[\011\040] )*)
                           \015?\012
                        /gxc;

                  /\G$/
                    or return (%state = (), $cb->(undef, { Status => 599, Reason => "garbled response headers", URL => $url }));
               }

               substr $_, 0, 1, ""
                  for values %hdr;

               my $finish = sub {
                  %state = ();

                  # set-cookie processing
                  if ($arg{cookie_jar} && exists $hdr{"set-cookie"}) {
                     for (split /\x00/, $hdr{"set-cookie"}) {
                        my ($cookie, @arg) = split /;\s*/;
                        my ($name, $value) = split /=/, $cookie, 2;
                        my %kv = (value => $value, map { split /=/, $_, 2 } @arg);
    
                        my $cdom  = (delete $kv{domain}) || $uhost;
                        my $cpath = (delete $kv{path})   || "/";
    
                        $cdom =~ s/^.?/./; # make sure it starts with a "."

                        next if $cdom =~ /\.$/;
    
                        # this is not rfc-like and not netscape-like. go figure.
                        my $ndots = $cdom =~ y/.//;
                        next if $ndots < ($cdom =~ /\.[^.][^.]\.[^.][^.]$/ ? 3 : 2);
    
                        # store it
                        $arg{cookie_jar}{version} = 1;
                        $arg{cookie_jar}{$cdom}{$cpath}{$name} = \%kv;
                     }
                  }

                  if ($_[1]{Status} =~ /^30[12]$/ && $recurse) {
                     # microsoft and other assholes don't give a shit for following standards,
                     # try to support a common form of broken Location header.
                     $_[1]{location} =~ s%^/%$scheme://$uhost:$uport/%;

                     http_request ($method, $_[1]{location}, %arg, recurse => $recurse - 1, $cb);
                  } else {
                     $cb->($_[0], $_[1]);
                  }
               };

               if ($hdr{Status} =~ /^(?:1..|204|304)$/ or $method eq "HEAD") {
                  $finish->(undef, \%hdr);
               } else {
                  if (exists $hdr{"content-length"}) {
                     $_[0]->unshift_read (chunk => $hdr{"content-length"}, sub {
                        # could cache persistent connection now
                        if ($hdr{connection} =~ /\bkeep-alive\b/i) {
                           # but we don't, due to misdesigns, this is annoyingly complex
                        };

                        $finish->($_[1], \%hdr);
                     });
                  } else {
                     # too bad, need to read until we get an error or EOF,
                     # no way to detect winged data.
                     $_[0]->on_error (sub {
                        $finish->($_[0]{rbuf}, \%hdr);
                     });
                     $_[0]->on_eof (undef);
                     $_[0]->on_read (sub { });
                  }
               }
            });
         });
      }, sub {
         $timeout
      };
   };

   defined wantarray && AnyEvent::Util::guard { %state = () }
}

sub http_get($@) {
   unshift @_, "GET";
   &http_request
}

sub http_head($@) {
   unshift @_, "HEAD";
   &http_request
}

sub http_post($$@) {
   my $uri = shift;
   unshift @_, "POST", shift, "body";
   &http_request
}

=back

=head2 GLOBAL FUNCTIONS AND VARIABLES

=over 4

=item AnyEvent::HTTP::set_proxy "proxy-url"

Sets the default proxy server to use. The proxy-url must begin with a
string of the form C<http://host:port> (optionally C<https:...>).

=item $AnyEvent::HTTP::MAX_RECURSE

The default value for the C<recurse> request parameter (default: C<10>).

=item $AnyEvent::HTTP::USERAGENT

The default value for the C<User-Agent> header (the default is
C<Mozilla/5.0 (compatible; AnyEvent::HTTP/$VERSION; +http://software.schmorp.de/pkg/AnyEvent)>).

=item $AnyEvent::HTTP::MAX_PERSISTENT

The maximum number of persistent connections to keep open (default: 8).

Not implemented currently.

=item $AnyEvent::HTTP::PERSISTENT_TIMEOUT

The maximum time to cache a persistent connection, in seconds (default: 2).

Not implemented currently.

=item $AnyEvent::HTTP::ACTIVE

The number of active connections. This is not the number of currently
running requests, but the number of currently open and non-idle TCP
connections. This number of can be useful for load-leveling.

=back

=cut

sub set_proxy($) {
   $PROXY = [$2, $3 || 3128, $1] if $_[0] =~ m%^(https?):// ([^:/]+) (?: : (\d*) )?%ix;
}

# initialise proxy from environment
set_proxy $ENV{http_proxy};

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

   Marc Lehmann <schmorp@schmorp.de>
   http://home.schmorp.de/

=cut

1

