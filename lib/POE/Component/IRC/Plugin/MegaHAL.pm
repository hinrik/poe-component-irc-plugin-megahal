package POE::Component::IRC::Plugin::MegaHAL;

use strict;
use warnings;
use POE;
use POE::Component::AI::MegaHAL;
use POE::Component::IRC::Common qw(l_irc);
use POE::Component::IRC::Plugin qw(:ALL);
use POE::Component::IRC::Plugin::BotAddressed;

our $VERSION = '0.01';

sub new {
    my $package = shift;
    my $self = bless { @_ }, $package;

    if (ref $self->{MegaHAL} ne 'POE::Component::AI::MegaHAL') {
        $self->{MegaHAL} = POE::Component::AI::MegaHAL->spawn(( $self->{MegaHAL_args} ? %{ $self->{MegaHAL_args} } : () ));
    }

    return $self;
}

sub PCI_register {
    my ($self, $irc) = @_;

    if (!$irc->isa('POE::Component::IRC::State')) {
        die __PACKAGE__ . ' requires PoCo::IRC::State or a subclass thereof';
    }
    
    $self->{irc} = $irc;
    $self->{session_id} = POE::Session->create(
        object_states => [
            $self => [qw(_start _reply _repost)],
        ],
    )->ID();

    if (!grep { $_->isa('POE::Component::IRC::Plugin::BotAddressed') } values %{ $irc->plugin_list() }) {
        $irc->plugin_add('BotAddressed', POE::Component::IRC::Plugin::BotAddressed->new());
    }

    if ($self->{Own_channel} && !$irc->is_channel_member($irc->nick_name())) {
        $irc->yield(join => $self->{Own_channel});
    }

    $irc->plugin_register($self, 'SERVER', qw(001 bot_addressed ctcp_action msg public));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;

    delete $self->{irc};
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub _start {
    my ($kernel, $self) = @_[KERNEL, OBJECT];
    return;
}

sub _reply {
    my $irc = $_[OBJECT]->{irc};
    my $info = $_[ARG0];
    $irc->yield(privmsg => $info->{_target}, $info->{reply});
    return;
}

# a trick to make do_reply() and such be called from *our* POE session
sub _repost {
    $_[ARG0]->($_[OBJECT]);
    return;
}

sub _ignoring {
    my ($self, $mask) = @_;
    return;
}

sub S_001 {
    my ($self, $irc) = splice @_, 0, 2;
    $irc->yield(join => $self->{Own_channel}) if $self->{Own_channel};
    return PCI_EAT_NONE;
}

sub S_bot_addressed {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick = (split /!/, ${ $_[0] })[0];
    my $chan = ${ $_[1] }->[0];
    my $what = ${ $_[2] };

    return if $self->{Own_channel} && l_irc($chan) eq l_irc($self->{Own_channel});
    return if $self->{Channels} && !grep { l_irc($_) eq l_irc($chan) } @{ $self->{Channels} };
    #return if ignore
    
    $poe_kernel->post($self->{session_id} => _repost => sub {
        my ($self) = @_;
        $poe_kernel->post($self->{MegaHAL}->session_id() => do_reply => {
            event   => '_reply',
            text    => $what,
            _target => $chan,
        });
    });

    return PCI_EAT_NONE;
}

sub S_ctcp_action {
    my ($self, $irc) = splice @_, 0, 2;
    my $who       = ( split /!/, ${ $_[0] } )[0];
    my $addressed = ${ $_[1] }->[0];
    my $what      = ${ $_[2] };

    # learn if
    # return if

    $poe_kernel->post($self->{session_id} => _repost => sub {
        my ($self) = @_;
        $poe_kernel->post($self->{MegaHAL}->session_id() => do_reply => {
            event   => '_reply',
            text    => $what,
            _target => $addressed,
        });
    });


    return PCI_EAT_NONE;
}

sub S_msg {
    my ($self, $irc) = splice @_, 0, 2;
    return PCI_EAT_NONE;
}

sub S_public {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick = ( split /!/, ${ $_[0] } )[0];
    my $chan = ${ $_[1] }->[0];
    my $what = ${ $_[2] };
    
    return if !$self->{Own_channel};
    return if l_irc($chan) ne l_irc($self->{Own_channel});
    # return if ignore
    
    $poe_kernel->post($self->{session_id} => _repost => sub {
        my ($self) = @_;
        $poe_kernel->post($self->{MegaHAL}->session_id() => do_reply => {
            event   => '_reply',
            text    => $what,
            _target => $chan,
        });
    });

    return PCI_EAT_NONE;
}

1;
__END__

=head1 NAME

POE::Component::IRC::Plugin::MegaHAL - A PoCo-IRC plugin which wraps an
instance of L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL>.

=head1 SYNOPSIS

 use POE::Component::IRC::Plugin::MegaHAL;

 $irc->plugin_add('MegaHAL', POE::Component::IRC::Plugin::MegaHAL(
     MegaHAL_args => {
         path     => '/my/brain.brn',
         autosave => 1,
     },
     Channels     => ['#here', '#there'],
     Own_channel  => '#the_brain',
     Ignore       => ['purl!*@*'],
 ));

=head1 DESCRIPTION

POE::Component::IRC::Plugin::MegaHAL is a L<POE::Component::IRC|POE::Component::IRC>
plugin.

This plugin requires the IRC component to be L<POE::Component::IRC::State|POE::Component::IRC::State>
or a subclass thereof. It also requires a L<POE::Component::IRC::Plugin::BotAddressed|POE::Component::IRC::Plugin::BotAddressed>
to be in the plugin pipeline. It will be added automatically if it is not
present.

=head2 METHODS

=head2 C<new>

Takes the following optional arguments:

'MegaHAL', reference to an existing
L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL> object you have
lying around. Useful if you want to use it with multiple IRC components.
If this argument is not provided, the plugin will construct its own object.

'MegaHAL_args', a hash reference containing arguments to pass to the constructor
of a new L<POE::Component::AI::MegaHAL|POE::Component::AI::MegaHAL> object.

'Channels', the channels where it will reply to people upon being addressed
Defaults to all the channels which the IRC component is on.

'Own_channel', a channel where it will reply to all messages. It will try to
join this channel if the IRC component is not already on it. It will also
part from that channel when the plugin is removed. Defaults to none.

'Ignore', an array reference of IRC masks (e.g. "purl!*@*") to ignore.

Returns a plugin object suitable for feeding to
L<POE::Component::IRC|POE::Component::IRC>'s plugin_add() method.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=cut
