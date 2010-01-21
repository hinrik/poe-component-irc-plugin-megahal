use strict;
use warnings;
use File::Spec::Functions 'catfile';
use Test::More tests => 2;
use Test::Script;
use_ok 'POE::Component::IRC::Plugin::MegaHAL';
script_compiles_ok(catfile('script', 'irchal-seed'));
