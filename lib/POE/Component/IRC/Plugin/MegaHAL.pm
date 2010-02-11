package POE::Component::IRC::Plugin::MegaHAL;

use strict;
use warnings;
use Carp;
use Encode qw(decode);
use POE;
use POE::Component::AI::MegaHAL;
use POE::Component::IRC::Common qw(l_irc matches_mask_array irc_to_utf8 strip_color strip_formatting);
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);

our $VERSION = '0.32';

sub new {
    my ($package, %args) = @_;
    my $self = bless \%args, $package;

    if (ref $self->{MegaHAL} eq 'POE::Component::AI::MegaHAL') {
        $self->{keep_alive} = 1;
    }
    else {
        $self->{MegaHAL} = POE::Component::AI::MegaHAL->spawn(
            ($self->{MegaHAL_args} ? %{ $self->{MegaHAL_args} } : () ),
        );
    }

    $self->{Method} = 'notice' if !defined $self->{Method} || $self->{Method} !~ /privmsg|notice/;
    $self->{abusers} = { };
    $self->{Abuse_interval} = 60 if !defined $self->{Abuse_interval};

    return $self;
}

sub PCI_register {
    my ($self, $irc) = @_;

    if (!$irc->isa('POE::Component::IRC::State')) {
        die __PACKAGE__ . " requires PoCo::IRC::State or a subclass thereof\n";
    }

    $self->{irc} = $irc;
    POE::Session->create(
        object_states => [
            $self => [qw(_start _megahal_reply _megahal_greeting _greet_handler _msg_handler)],
        ],
    );

    $irc->plugin_register($self, 'SERVER', qw(isupport ctcp_action join public));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;

    $irc->yield(part => $self->{Own_channel}) if $self->{Own_channel};
    delete $self->{irc};
    $poe_kernel->post($self->{MegaHAL}->session_id() => 'shutdown') unless $self->{keep_alive};
    delete $self->{MegaHAL};
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub _start {
    my ($kernel, $self, $session) = @_[KERNEL, OBJECT, SESSION];
    $self->{session_id} = $session->ID();
    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
    return;
}

sub _megahal_reply {
    my ($self, $info) = @_[OBJECT, ARG0];
    my $reply = $self->_normalize_megahal($info->{reply});
    
    $self->{irc}->yield($self->{Method} => $info->{_target}, $reply);
    return;
}

sub _megahal_greeting {
    my ($self, $info) = @_[OBJECT, ARG0];
    my $reply = $self->_normalize_megahal($info->{reply});
    $reply = "$info->{_nick}: $reply";
    
    $self->{irc}->yield($self->{Method} => $info->{_target}, $reply);
    return;
}

sub _ignoring_user {
    my ($self, $user, $chan) = @_;
    
    if ($self->{Ignore_masks}) {
        my $mapping = $self->{irc}->isupport('CASEMAPPING');
        return 1 if keys %{ matches_mask_array($self->{Ignore_masks}, [$user], $mapping) };
    }

    # abuse protection
    my $key = "$user $chan";
    my $last_time = delete $self->{abusers}->{$key};
    $self->{abusers}->{$key} = time;
    return 1 if $last_time && (time - $last_time < $self->{Abuse_interval});
    
    return;
}

sub _msg_handler {
    my ($self, $kernel, $type, $user, $chan, $what) = @_[OBJECT, KERNEL, ARG0..$#_];

    return if $self->_ignoring_user($user, $chan);
    $what = _normalize_irc($what);

    # should we reply?
    my $event = '_no_reply';
    my $nick = $self->{irc}->nick_name();
    if ($self->{Own_channel} && (l_irc($chan) eq l_irc($self->{Own_channel}))
        || $type eq 'public' && $what =~ s/^\s*\Q$nick\E[:,;.!?~]?\s//i
        || $self->{Talkative} && $what =~ /\Q$nick/i)
    {
        $event = '_megahal_reply';
    }

    if ($self->{Ignore_regexes}) {
        for my $regex (@{ $self->{Ignore_regexes} }) {
            return if $what =~ $regex;
        }
    }

    $kernel->post($self->{MegaHAL}->session_id() => do_reply => {
        event   => $event,
        text    => $what,
        _target => $chan,
    });

    return;
}

sub _greet_handler {
    my ($self, $kernel, $user, $chan) = @_[OBJECT, KERNEL, ARG0, ARG1];

    return if $self->_ignoring_user($user, $chan);
    return if !$self->{Own_channel} || (l_irc($chan) ne l_irc($self->{Own_channel}));

    $kernel->post($self->{MegaHAL}->session_id() => initial_greeting => {
        event   => '_megahal_greeting',
        _target => $chan,
        _nick   => (split /!/, $user)[0],
    });

    return;
}

sub _normalize_megahal {
    my ($self, $line) = @_;

    $line = decode('utf8', $line);
    if ($self->{English}) {
        $line =~ s{\bi\b}{I}g;
        $line =~ s{(?<=\w)$}{.};
    }
    return $line;
}

sub _normalize_irc {
    my ($line) = @_;

    $line = irc_to_utf8($line);
    $line = strip_color($line);
    $line = strip_formatting($line);
    return $line;
}

sub brain {
    my ($self) = @_;
    return $self->{MegaHAL};
}

sub transplant {
    my ($self, $brain) = @_;
    
    if (ref $brain ne 'POE::Component::AI::MegaHAL') {
        croak 'Argument must be a POE::Component::AI::MegaHAL instance';
    }

    my $old_brain = $self->{MegaHAL};
    $poe_kernel->post($self->{MegaHAL}->session_id(), 'shutdown') if !$self->{keep_alive};
    $self->{MegaHAL} = $brain;
    $self->{keep_alive} = 1;
    return $old_brain;
}

sub S_isupport {
    my ($self, $irc) = splice @_, 0, 2;
    $irc->yield(join => $self->{Own_channel}) if $self->{Own_channel};
    return PCI_EAT_NONE;
}

sub S_ctcp_action {
    my ($self, $irc) = splice @_, 0, 2;
    my $user         = ${ $_[0] };
    my $nick         = (split /!/, $user)[0];
    my $chan         = ${ $_[1] }->[0];
    my $what         = ${ $_[2] };

    return PCI_EAT_NONE if $chan !~ /^[#&!]/;
    
    $poe_kernel->post(
        $self->{session_id},
        '_msg_handler',
        'action',
        $user, 
        $chan,
        "$nick $what",
    ); 
    
    return PCI_EAT_NONE;
}

sub S_public {
    my ($self, $irc) = splice @_, 0, 2;
    my $user         = ${ $_[0] };
    my $chan         = ${ $_[1] }->[0];
    my $what         = ${ $_[2] };

    $poe_kernel->post($self->{session_id} => _msg_handler => 'public', $user, $chan, $what);
    return PCI_EAT_NONE;
}

sub S_join {
    my ($self, $irc) = splice @_, 0, 2;
    my $user         = ${ $_[0] };
    my $chan         = ${ $_[1] };

    return PCI_EAT_NONE if (split /!/, $user)[0] eq $irc->nick_name();
    $poe_kernel->post($self->{session_id} => _greet_handler => $user, $chan);
    return PCI_EAT_NONE;
}

1;
__END__

=head1 NAME

POE::Component::IRC::Plugin::MegaHAL - A PoCo-IRC plugin which provides
access to a MegaHAL conversation simulator.

=head1 SYNOPSIS

 #!/usr/bin/env perl
 
 use strict;
 use warnings;
 use POE;
 use POE::Component::IRC::Plugin::AutoJoin;
 use POE::Component::IRC::Plugin::Connector;
 use POE::Component::IRC::Plugin::MegaHAL;
 use POE::Component::IRC::State;
 
 my $irc = POE::Component::IRC::State->spawn(
     nick   => 'Brainy',
     server => 'irc.freenode.net',
 );
 
 my @channels = ('#public_chan', '#bot_chan');
 
 $irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new(Channels => \@channels));
 $irc->plugin_add('Connector', POE::Component::IRC::Plugin::Connector->new());
 $irc->plugin_add('MegaHAL', POE::Component::IRC::Plugin::MegaHAL->new(
     Own_channel    => '#bot_chan',
     English        => 1,
     Ignore_regexes => [ qr{^\s*\w+://\S+\s*$} ], # ignore URL-only lines
 ));
 
 $irc->yield('connect');
 $poe_kernel->run();

=head1 DESCRIPTION

POE::Component::IRC::Plugin::MegaHAL is a
L<POE::Component::IRC|POE::Component::IRC> plugin. It provides "intelligence"
through the use of L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHal>.
It will talk back when addressed by channel members (and possibly in other
situations, see L<C<new>|/"new">). An example:

 --> megahal_bot joins #channel
 <Someone> oh hi
 <Other> hello there
 <Someone> megahal_bot: hi there
 <megahal_bot> oh hi

All NOTICEs are ignored, so if your other bots only issue NOTICEs like
they should, they will be ignored automatically.

Before using, you should read the documentation for
L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL> and by extension,
L<AI::MegaHAL|AI::MegaHAL>, so you have an idea of what to pass as the
B<'MegaHAL_args'> parameter to L<C<new>|/"new">.

This plugin requires the IRC component to be
L<POE::Component::IRC::State|POE::Component::IRC::State> or a subclass thereof.

=head1 METHODS

=head2 C<new>

Takes the following optional arguments:

B<'MegaHAL'>, a reference to an existing
L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL> object you have
lying around. Useful if you want to use it with multiple IRC components.
If this argument is not provided, the plugin will construct its own object.

B<'MegaHAL_args'>, a hash reference containing arguments to pass to the
constructor of a new L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL>
object.

B<'Own_channel'>, a channel where it will reply to all messages, as well as
greet everyone who joins. The plugin will take care of joining the channel.
It will part from it when the plugin is removed from the pipeline. Defaults
to none.

B<'Abuse_interval'>, default is 60 (seconds), which means that user X in
channel Y has to wait that long before addressing the bot in the same channel
if he doesn't want to be ignored. Setting this to 0 effectively turns off
abuse protection.

B<'Talkative'>, when set to a true value, the bot will respond whenever
someone mentions its name (in a PRIVMSG or CTCP ACTION (/me)). If false, it
will only respond when addressed directly with a PRIVMSG. Default is false.

B<'Ignore_masks'>, an array reference of IRC masks (e.g. "purl!*@*") to
ignore.

B<'Ignore_regexes'>, an array reference of regex objects. If a message
matches any of them, it will be ignored. Handy for ignoring messages with
URLs in them.

B<'Method'>, how you want messages to be delivered. Valid options are
'notice' (the default) and 'privmsg'.

B<'English'>, when set to a true value, some English-language corrections
will be applied to the bot's output. Currently it will capitalizes the word
'I' and make sure paragraphs end with '.' where appropriate. Defaults to
false.

Returns a plugin object suitable for feeding to
L<POE::Component::IRC|POE::Component::IRC>'s plugin_add() method.

=head2 C<brain>

Takes no arguments. Returns the underlying
L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL> object being used
by the plugin.

=head2 C<transplant>

Replaces the brain with the supplied
L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL> instance. Shuts
down the old brain if it was instantiated by the plugin itself.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 KUDOS

Those go to Chris C<BinGOs> Williams and his friend GumbyBRAIN.

=cut
