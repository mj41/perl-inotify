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

# create a new object
my $inotify = new Linux::Inotify2::Recur( $ver )
    or croak "Unable to create new inotify object: $!";


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
