use ExtUtils::MakeMaker;

my $mm = MM->new({
    dist         => {
       PREOP	=> 'pod2text HTTP.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
	            },
    NAME         => "AnyEvent::HTTP",
    VERSION_FROM => "HTTP.pm",
    PREREQ_PM    => {
       AnyEvent     => 4.14,
       Scalar::Util => 0,
    },
});

$mm->flush;

