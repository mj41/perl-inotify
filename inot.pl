use strict;
use warnings;

use Carp qw(carp croak verbose);
use Data::Dumper;

use lib 'lib';
use Linux::Inotify2::Recur;


my $devel = ! $ARGV[0];

# Verbosity level.
my $ver = 8;
$ver = 2 unless $devel;
$ver = $ARGV[1] if $ARGV[1];


my $dirs_to_watch = [];

$dirs_to_watch = [
    '/home/mj/',
];

if ( $devel ) {
    print "Running in devel mode. Verbose level $ver.\n";
    $dirs_to_watch = [
        './test-dir',
    ];
}


my $grep_dirs_sub = sub {
    my ( $dir ) = @_;
    
    # Ignore subversion directories.
    return 0 if $dir =~ m{/\.svn$};
    return 0 if $dir =~ m{/\.svn/};

    # Ignore temp directories.
    return 0 if $dir =~ m{/temp$};
    return 0 if $dir =~ m{/temp/};
    return 1;
};

my $my_event_handle = sub {
    my ( $time, $fullname, $e, $ver, $moved_from ) = @_;
    
    if ( $e->IN_ISDIR ) {
        print "====> my_event_handle: Directory '$fullname'.\n" if $ver >= 3;

    } elsif ( $fullname =~ m{/\.swp$} # vi editor backup
           || $fullname =~ m{/\.swx$} # vi editor backup
           || $fullname =~ m{/tempfile\.tmp$} # svn update tempfile
           || $fullname =~ m{/\.\#[^\/]+]$} # mc editor backup
    ) {
        print "====> my_event_handle: Skipping temp filename '$fullname'.\n" if $ver >= 5;

    } else {
        if ( $e->IN_CLOSE_WRITE ) {
            print "====> my_event_handle: File '$fullname'.\n" if $ver >= 3;
        }
    }

    return 1;
};

# create a new object
my $inotify = new Linux::Inotify2::Recur({
    'ver' => $ver,
    'grep_dirs_sub' => $grep_dirs_sub,
    'my_event_handle' => $my_event_handle,
}) or croak "Unable to create new inotify object: $!";


sub mdump {
    my ( $data ) = @_;

    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Sortkeys = 1;
    return Data::Dumper->Dump( [ $data ], [] ) . "\n";
}

$inotify->add_dirs( $dirs_to_watch );
#print mdump( $inotify );

# Main event loop.
1 while $inotify->pool();
