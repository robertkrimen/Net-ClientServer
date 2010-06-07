package Net::ClientServer;
# ABSTRACT: A single platform for launching servers and connecting clients

use strict;
use warnings;

#use Net::ClientServer::Server::FIFO;
#use Net::ClientServer::Server::Fork;
#use Net::ClientServer::Server::Prefork;

use Any::Moose;

use Daemon::Daemonize qw/ write_pidfile check_pidfile delete_pidfile /;
use Path::Class;
use IO::Socket::INET;
use File::HomeDir;
use Path::Class;
use Carp;
use Net::ClientServer::Server;

has host => qw/ is ro /;
has port => qw/ is ro required 1 /;

has daemon => qw/ is rw default 1 /;
sub _daemon_options { }
has server => qw/ is rw isa HashRef /;
sub _server_options {
    my $self = shift;
    return %{ $self->server };
};

sub BUILD {
    my $self = shift;
    my $given = shift;
    my $file_default = 1;
    $file_default = 0 if $given->{fileless};
    $self->_given_pid_file( $file_default ) unless $self->has_pid_file;
    $self->_given_stderr_file( $file_default ) unless $self->has_stderr_file;
}

for my $field (qw/ name home pid_file stderr_file /) {
    my $given = "_given_$field";
    my $built = "_built_$field";
    my $build = "_build_$field";
    my $reset = "_reset_$field";
    has $given => qw/ is rw /, init_arg => $field, predicate => "has_$field";
    has $built => qw/ is ro lazy  1 /, clearer => $reset, builder => $build;
    __PACKAGE__->meta->add_method( $field => sub {
        my $self = shift;
        if ( @_ ) {
            $self->$given( $_[0] );
            $self->$reset;
        }
        return $self->$built;
    } );
}

sub _build_name { return $_[0]->_given_name }
sub _build_home {
    my $self = shift;
    my @dir;
    if ( $self->has_home ) {
        return unless my $home = $self->_given_home;
        push @dir, $home if $home ne 1;
    }
    unless ( @dir ) {
        croak "Missing name for home" unless my $name = $self->name;
        push @dir, File::HomeDir->my_home, join '', ".$name";
    }
    return dir( @dir )->absolute;
}
sub _yield_field {
    my $self = shift;
    my $field = shift;
    my $default = shift;

    my $given = "_given_$field";
    my $has = "has_$field";
    
    my $file = 1;
    $file = $self->$given if $self->$has;;
    return unless defined $file;
    $file = $default if $file eq '1';
    if      ( $file =~ m/^\// )     {}
    elsif   ( $file =~ m/^\.\// )   {}
    else {
        croak "Missing home for $field" unless $self->has_home || $self->has_name;
        $file = $self->home->file( $file )
    }
    return file( $file )->absolute;
}
sub _build_pid_file {
    my $self = shift;
    return $self->_yield_field( 'pid_file', 'pid' );
}
sub _build_stderr_file {
    my $self = shift;
    return $self->_yield_field( 'stderr_file', 'stderr' );
}

#open(STDERR,"|/bin/logger -t \"${PROGNAME}[$$]: STDERR\"") or die "Error: Unable to redirect STDERR to logger!";
#open(STDOUT,"|/bin/logger -t \"${PROGNAME}[$$]: STDOUT\"") or die "Error: Unable to redirect STDOUT to logger!";

sub server_socket {
    my $self = shift;
    return Net::ClientServer::Server->server_socket( host => $self->host, port => $self->port, @_ );
}

sub client_socket {
    my $self = shift;
    my $host = $self->host;
    $host = 'localhost' unless defined $host && length $host;
    my $port = $self->port;
    return IO::Socket::INET->new( PeerHost => $host, PeerPort => $port, Proto => 'tcp' );
}

sub pid {
    my $self = shift;
    return check_pidfile( $self->pid_file );
}

sub delete_pid {
    my $self = shift;
    return unless $self->has_pid_file && ( my $pid_file = $self->pid_file );
    delete_pidfile( $pid_file );
}

sub started {
    my $self = shift;
    return 1 if $self->pid || $self->client_socket;
    return 0;
}

sub start {
    my $self = shift;
    return if $self->started;
    if ( $self->daemon )    { $self->daemonize( _run => sub { $self->serve } ) }
    else                    { $self->serve }
}

sub _file_mkdir {
    my $self = shift;
    my $file = shift;
    return unless $file;
    $file = file( $file ) if ref $file eq '';
    return unless blessed $file && $file->isa( 'Path::Class::File' );
    $file->parent->mkpath;
}

sub daemonize {
    my $self = shift;
    my %options = @_;

    my $platform = $self;
    my @daemon_arguments;

    push @daemon_arguments, chdir => undef, close => 1;

    if ( $self->has_stderr_file && ( my $stderr_file = $self->stderr_file ) ) {
        $self->_file_mkdir( $stderr_file );
        push @daemon_arguments, stderr => $stderr_file;
    }

    my $pid_file;
    if ( $self->has_pid_file && ( $pid_file = $self->pid_file ) ) {
        $self->_file_mkdir( $pid_file );
        push @daemon_arguments, pid_file => $pid_file;
    }

    my %daemon = $self->_daemon_options;

    my ( $override_run, $run, $_run ) =
        ( delete @daemon{qw/ override_run run /}, $options{_run} );

    if ( $override_run ) {
        push @daemon_arguments, run => $override_run;
    }
    else { 
        $run = $_run unless $run;
        push @daemon_arguments, run => sub {
            if ( $pid_file ) {
                write_pidfile( $pid_file );
                $SIG{TERM} = $SIG{INT} = sub { delete_pidfile( $pid_file ) }
            }
            $run->( $platform );
        };
    }

    push @daemon_arguments, %daemon;

    Daemon::Daemonize->daemonize( chdir => undef, close => 1, @daemon_arguments );

    if ( $pid_file ) {
        do { sleep 1 } until -s $pid_file;
    }
}

sub serve {
    my $self = shift;

    my $platform = $self;
    my %server_options = $self->_server_options;

    for (qw/ start stop run /) {
        next unless my $code = $server_options{$_};
        $server_options{$_} = sub { $code->( @_, $platform ) };
    }
    Net::ClientServer::Server->serve( host => $self->host, port => $self->port, %server_options );
}

# Stoled from Net::Server
sub stdin2socket {
    my $self = shift;
    my $socket = shift;

    my $fileno = fileno $socket;
    close STDIN;
    if ( defined $fileno ) {
        open STDIN, "<&$fileno" or die "Unable open STDIN to socket: $!";
    }
    else {
        *STDIN= \*{ $socket };
    }
    STDIN->autoflush( 1 );
}

# Stoled from Net::Server
sub stdout2socket {
    my $self = shift;
    my $socket = shift;

    my $fileno = fileno $socket;
    close STDOUT;
    if ( defined $fileno ) {
        open STDOUT, ">&$fileno" or die "Unable open STDOUT to socket: $!";
    }
    else {
        *STDOUT= \*{ $socket } unless $socket->isa( 'IO::Socket::SSL' );
    }
    STDOUT->autoflush( 1 );
}

# Stoled from Net::Server
sub stderr2socket {
    my $self = shift;
    my $socket = shift;

    my $fileno = fileno $socket;
    close STDERR;
    if ( defined $fileno ) {
        open STDERR, ">&$fileno" or die "Unable open STDERR to socket: $!";
    }
    else {
        *STDERR= \*{ $socket } unless $socket->isa( 'IO::Socket::SSL' );
    }
    STDERR->autoflush( 1 );
}

1;
