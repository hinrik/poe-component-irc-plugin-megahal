use strict;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'POE::Component::IRC::Plugin::MegaHAL',
    AUTHOR        => 'Hinrik Örn Sigurðsson <hinrik.sig@gmail.com>',
    VERSION_FROM  => 'lib/POE/Component/IRC/Plugin/MegaHAL.pm',
    ABSTRACT_FROM => 'lib/POE/Component/IRC/Plugin/MegaHAL.pm',
    LICENSE       => 'perl',
    EXE_FILES     => [ 'script/irchal_seed' ],
    PREREQ_PM     => {
        'POE::Component::AI::MegaHAL' => '0',
        'POE::Component::IRC'         => '0',
    },

    clean => { FILES => 't/megahal.dic t/megahal.brn' }
);
