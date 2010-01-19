use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'POE::Component::IRC::Plugin::MegaHAL',
    AUTHOR        => 'Hinrik Örn Sigurðsson <hinrik.sig@gmail.com>',
    VERSION_FROM  => 'lib/POE/Component/IRC/Plugin/MegaHAL.pm',
    ABSTRACT_FROM => 'lib/POE/Component/IRC/Plugin/MegaHAL.pm',
    ($ExtUtils::MakeMaker::VERSION ge '6.31'
        ? (LICENSE => 'perl')
        : ()
    ),
    EXE_FILES     => [ 'script/irchal-seed' ],
    PREREQ_PM     => {
        'Encode'                      => '0',
        'POE::Component::AI::MegaHAL' => '1.18',
        'POE::Component::IRC'         => '6.20',
    },
    clean => { FILES => 't/megahal.dic t/megahal.brn' }
);
