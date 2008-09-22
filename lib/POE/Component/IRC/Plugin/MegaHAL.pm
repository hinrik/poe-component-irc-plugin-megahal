package POE::Component::IRC::Plugin::MegaHAL;

use strict;
use warnings;
use Carp;
use POE;
use POE::Component::AI::MegaHAL;
use POE::Component::IRC::Common qw(l_irc matches_mask_array strip_color strip_formatting);
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);
use POE::Component::IRC::Plugin::BotAddressed;

our $VERSION = '0.06';

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
    $self->{flooders} = { };
    $self->{Flood_interval} = 60 if !defined $self->{Flood_interval};

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
            $self => [qw(_start _megahal_reply _megahal_greeting _greet_handler _own_handler _other_handler)],
        ],
    );

    if (!grep { $_->isa('POE::Component::IRC::Plugin::BotAddressed') } values %{ $irc->plugin_list() }) {
        $irc->plugin_add('BotAddressed', POE::Component::IRC::Plugin::BotAddressed->new());
    }

    if ($self->{Own_channel} && !$irc->is_channel_member($irc->nick_name())) {
        $irc->yield(join => $self->{Own_channel});
    }

    $irc->plugin_register($self, 'SERVER', qw(001 bot_addressed bot_mentioned bot_mentioned_action ctcp_action join public));
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
    $self->{irc}->yield($self->{Method} => $info->{_target}, $info->{reply});
    return;
}

sub _megahal_greeting {
    my ($self, $info) = @_[OBJECT, ARG0];
    my $reply = "$info->{_nick}: $info->{reply}";
    $self->{irc}->yield($self->{Method} => $info->{_target}, $reply);
    return;
}

sub _ignoring {
    my ($self, $user, $chan) = @_;
    
    return if !$self->{Ignore};
    my $mapping = $self->{irc}->isupport('CASEMAPPING');
    return 1 if keys %{ matches_mask_array($self->{Ignore}, [$user], $mapping) };
    return;
}

sub _own_handler {
    my ($self, $kernel, $user, $chan, $what) = @_[OBJECT, KERNEL, ARG0..$#_];
    
    return if $self->_ignoring($user);

    my $event = '_blank';
    if ($self->{Own_channel} && l_irc($self->{Own_channel}) eq l_irc($chan)) {
        $event = '_megahal_reply';
    }

    $what = strip_color($what);
    $what = strip_formatting($what);
    
    $kernel->post($self->{MegaHAL}->session_id() => do_reply => {
        event   => $event,
        text    => $what,
        _target => $chan,
    });

    return;
}

sub _other_handler {
    my ($self, $kernel, $user, $chan, $what) = @_[OBJECT, KERNEL, ARG0..$#_];

    return if $self->_ignoring($user);
    return if $self->{Own_channel} && (l_irc($chan) eq l_irc($self->{Own_channel}));
    
    # flood protection
    my $key = "$user $chan";
    my $last  = delete $self->{flooders}->{$key};
    $self->{flooders}->{$key} = time;
    return if $last && (time - $last < $self->{Flood_interval});
    
    $what = strip_color($what);
    $what = strip_formatting($what);

    $kernel->post($self->{MegaHAL}->session_id() => do_reply => {
        event   => '_megahal_reply',
        text    => $what,
        _target => $chan,
    });
    
    return;
}

sub _greet_handler {
    my ($self, $kernel, $user, $chan) = @_[OBJECT, KERNEL, ARG0, ARG1];

    return if $self->_ignoring($user);
    return if !$self->{Own_channel} || (l_irc($chan) ne l_irc($self->{Own_channel}));

    $kernel->post($self->{MegaHAL}->session_id() => initial_greeting => {
        event   => '_megahal_greeting',
        _target => $chan,
        _nick   => (split /!/, $user)[0],
    });
    return;
}

sub brain {
    my ($self) = @_;
    return $self->{MegaHAL};
}

sub transplant {
    my ($self, $brain) = @_;
    
    croak 'Argument must be a POE::Component::AI::MegaHAL instance' if ref $brain ne 'POE::Component::AI::MegaHAL';
    my $old_brain = $self->{MegaHAL};
    $poe_kernel->post($self->{MegaHAL}->session_id(), 'shutdown') unless $self->{keep_alive};
    $self->{MegaHAL} = $brain;
    $self->{keep_alive} = 1;
    return $old_brain;
}

sub S_001 {
    my ($self, $irc) = splice @_, 0, 2;
    $irc->yield(join => $self->{Own_channel}) if $self->{Own_channel};
    return PCI_EAT_NONE;
}

sub S_ctcp_action {
    my ($self, $irc) = splice @_, 0, 2;
    my $user         = ${ $_[0] };
    my $chan         = ${ $_[1] }->[0];
    my $what         = ${ $_[2] };

    return PCI_EAT_NONE if $chan !~ /^[#&!]/;
    $poe_kernel->post($self->{session_id} => _own_handler => $user, $chan, $what);
    return PCI_EAT_NONE;
}

sub S_bot_addressed {
    my ($self, $irc) = splice @_, 0, 2;
    my $user         = ${ $_[0] };
    my $chan         = ${ $_[1] }->[0];
    my $what         = ${ $_[2] };

    $poe_kernel->post($self->{session_id} => _other_handler => $user, $chan, $what);
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

no warnings 'once';
*S_public               = \&S_ctcp_action;
*S_bot_mentioned        = \&S_bot_addressed;
*S_bot_mentioned_action = \&S_bot_addressed;

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
     nick     => 'Brainy',
     server   => 'irc.freenode.net',
 );
 
 my @channels = ('#other_chan', '#my_chan');
 
 $irc->plugin_add('MegaHAL', POE::Component::IRC::Plugin::MegaHAL->new(Own_channel => '#my_chan'));
 $irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new(Channels => \@channels));
 $irc->plugin_add('Connector', POE::Component::IRC::Plugin::Connector->new());
 $irc->yield('connect');

 $poe_kernel->run();

=head1 DESCRIPTION

POE::Component::IRC::Plugin::MegaHAL is a L<POE::Component::IRC|POE::Component::IRC>
plugin. It provides "intelligence" through the use of
L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHal>.
It will respond when people either mention your nickname or address you.

This plugin requires the IRC component to be L<POE::Component::IRC::State|POE::Component::IRC::State>
or a subclass thereof. It also requires a L<POE::Component::IRC::Plugin::BotAddressed|POE::Component::IRC::Plugin::BotAddressed>
to be in the plugin pipeline. It will be added automatically if it is not
present.

=head1 METHODS

=head2 C<new>

Takes the following optional arguments:

'MegaHAL', a reference to an existing
L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL> object you have
lying around. Useful if you want to use it with multiple IRC components.
If this argument is not provided, the plugin will construct its own object.

'MegaHAL_args', a hash reference containing arguments to pass to the constructor
of a new L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL> object.

'Own_channel', a channel where it will reply to all messages, as well as greet
everyone who joins. It will try to join this channel if the IRC component is
not already on it. It will also part from it when the plugin is removed from
the pipeline. Defaults to none.

'Flood_interval', default is 60 (seconds), which means that user X in
channel Y has to wait that long before addressing the bot in the same channel
if he doesn't want to be ignored. The channel set with the 'Own_channel'
option (if any) is exempt from this. Setting this to 0 effectively turns off
flood protection.

'Ignore', an array reference of IRC masks (e.g. "purl!*@*") to ignore.

'Method', how you want messages to be delivered. Valid options are 'notice'
(the default) and 'privmsg'.

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
