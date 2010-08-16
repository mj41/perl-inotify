use strict;
use warnings;

# ToDo
# * separate config for watching files and directories
# * refactor to Perl package
# * add tests
# * add documentation

# Assumptions
# a) No MOVED_TO, MOVED_FROM order.
# b) No items related events between MOVED_FROM and MOVED_TO.
# c) MOVED_FROM and MOVED_TO not in two sepparated "$inotify->read"s.

use Carp qw(carp croak verbose);
use Data::Dumper;
use Time::HiRes qw(time sleep);
use POSIX;
use File::Find;

use lib 'lib';
use Linux::Inotify2;


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
my $inotify = new Linux::Inotify2
    or croak "Unable to create new inotify object: $!";


my $ev_names = {};
print "Events:\n" if $ver >= 5;
no strict 'refs';
for my $name (@Linux::Inotify2::EXPORT) {
   my $mask = &{"Linux::Inotify2::$name"};
   $ev_names->{$mask} = $name;
   print "   $name $mask\n" if $ver >= 5;
}
use strict 'refs';
print "\n" if $ver >= 5;


sub mdump {
    my ( $data ) = @_;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Sortkeys = 1;
    return Data::Dumper->Dump( [ $data ], [] ) . "\n";
}


sub dump_watched {
    my ( $inotify, $msg ) = @_;


    print "Watch list";
    print ' - ' . $msg if $msg;
    print ":\n";

    my $watchers = $inotify->{w};
    foreach my $key ( sort { $a <=> $b } keys %$watchers ) {
        my $watcher = $watchers->{ $key };
        print '   ' . $key . ' - ' . $watcher->{name} . ' : ' . $watcher->{mask} . "\n";
    }

    print "\n";

    return 1;
}


my $watcher_sub;
my $num_watched = 0;
my $num_to_watch = 0;
sub inotify_watch {
    my ( $dir ) = @_;

    print "Watching $dir\n" if $ver >= 4;

    my $watcher = $inotify->watch(
        $dir,
        ( IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE | IN_IGNORED | IN_UNMOUNT | IN_DELETE_SELF ),
        $watcher_sub
    );

    $num_to_watch++;
    if ( $watcher ) {
        $num_watched++;
    } else {
        print "Error adding watcher: $!\n";
    }
    dump_watched( $inotify, 'added new' ) if $ver >= 10;
    return $watcher;
}


sub watch_this {
    my ( $dir ) = @_;

    return 0 unless -d $dir;

    # Do not watch version control dirs.
    #return 0 if $dir =~ m{/.svn$/};
    #return 0 if $dir =~ m{/\.svn/};

    # Inside temp directory.
    #return 0 if $dir =~ m{/temp/};

    return 1;

}


sub item_to_watch {
    my ( $dir ) = @_;
    return undef unless watch_this( $dir );
    return inotify_watch( $dir );
}


sub items_to_watch_recursive {
    my ( $dirs_to_watch ) = @_;

    # Add watchers.
    return finddepth( {
            wanted => sub {
                item_to_watch( $_ );
            },
            no_chdir => 1,
        },
        @$dirs_to_watch
    );
}


sub item_to_remove_by_name {
    my ( $inotify, $item_torm_base, $recursive ) = @_;
    
    my $ret_code = 1;

    # Removing by name.
    my $item_torm_len = length( $item_torm_base );
    foreach my $watch ( values %{ $inotify->{w} } ) {
        my $remove = 0;
        my $item_name = $watch->{name};
        if ( $recursive ) {
            if ( length($item_name) >= $item_torm_len 
                 && substr($item_name,0,$item_torm_len) eq $item_torm_base 
            ) {
                $remove = 1;
            }

        } else {
            $remove = 1 if $item_name eq $item_torm_base;
        }
        
        if ( $remove ) {
            print "Stopping watching $item_name (by name '$item_torm_base', rec: $recursive).\n" if $ver >= 5;
            #print mdump( $watch );
            my $tmp_ret_code = $watch->cancel;
            dump_watched( $inotify, 'removed by name' ) if $ver >= 10;
            $ret_code = 0 unless $tmp_ret_code;
        }
    }
    
    return $ret_code;
}


sub item_to_remove_by_event {
    my ( $inotify, $item, $e, $recursive ) = @_;

    # Removing by object ref.
    print "Stopping watching $item (by object).\n" if $ver >= 5;
    my $ret_code = 1;
    if ( $recursive ) {
        my $items_inside_prefix = $item . '/';
        $ret_code = item_to_remove_by_name( $inotify, $items_inside_prefix, $recursive );
    }
    my $tmp_ret_code = $e->{w}->cancel;
    $ret_code = 0 unless $tmp_ret_code;
    dump_watched( $inotify, 'removed by ref' ) if $ver >= 10;
    return $ret_code;

    print "Error: Can't remove item '$item' (not found).\n" if $ver >= 1;
    return 0;
}


my $cookie_to_rm = {};
my $last_time = 0;
$watcher_sub = sub {
    my $e = shift;

    my $time = time();
    my $fullname = $e->fullname;

    if (    $fullname =~ m{/\.swp$} # vi editor backup
         || $fullname =~ m{/\.swx$} # vi editor backup
         # || $fullname =~ m{/tempfile\.tmp$} # svn update tempfile
    ) {
        print "Skipping '$fullname'.\n" if $ver >= 5;

    }  else {
        if ( $e->IN_CREATE ) {
            items_to_watch_recursive( [ $fullname ] );
            
        } elsif ( $e->IN_MOVED_TO ) {
            my $cookie = $e->{cookie};
            if ( exists $cookie_to_rm->{$cookie} ) {
                # Check if we want to watch new name.
                if ( watch_this($fullname) ) {
                    # Update path inside existing watch.
                    items_to_watch_recursive( [ $fullname ] );
                    delete $cookie_to_rm->{$cookie};

                # Remove old watch if exists.
                } elsif ( defined $cookie_to_rm->{$cookie} ) {
                    my $c_fullname = $cookie_to_rm->{$cookie};
                    item_to_remove_by_name( $inotify, $c_fullname, 1 );
                    delete $cookie_to_rm->{$cookie};

                # Remember new cookie.
                } else {
                    $cookie_to_rm->{ $e->{cookie} } = undef;
                }

            } else {
                items_to_watch_recursive( [ $fullname ] );
            }
        }

        my @lt = localtime($time);
        my $dt = sprintf("%02d.%02d.%04d %02d:%02d:%02d -", $lt[3], ($lt[4] + 1),( $lt[5] + 1900), $lt[2], $lt[1], $lt[0] );
        print $dt . ' ';

        my $mask = $e->{mask};
        if ( defined $mask ) {
            if ( defined $ev_names->{$mask} ) {
                print " " . $ev_names->{$mask};
            } else {
                foreach my $ev_mask (keys %$ev_names) {
                    if ( ($mask & $ev_mask) == $ev_mask ) {
                        my $name = $ev_names->{ $ev_mask };
                        print " $name";
                    }
                }
            }
        }

        print ' -- ' . $fullname;
        print ' (' . $e->{name} . ')' if $e->{name};
        print ", cookie: '" . $e->{cookie} . "'" if $e->{cookie};
        print "\n";

        # Print line separator only each second.
        if ( floor($time) != $last_time ) {
            print "-" x 80 . "\n";
            $last_time = floor($time);
        }
    }


    # Event on directory, but item inside changed.
    if ( length($e->{name}) ) {
        # Directory moved away.
        if ( $e->{mask} & IN_MOVED_FROM ) {
            my $cookie = $e->{cookie};
            if ( exists $cookie_to_rm->{$cookie} ) {
                # Nothing yo do. See assumption a).
                print "Warning: Probably moved_from after moved_to occurs.\n" if $ver >= 1;
            } else {
                # We don't know new name yet, so we can't decide what to do (update or remove watch).
                # See assumption b).
                $cookie_to_rm->{ $cookie } = $fullname;
            }
        }

    # Event on item itself.
    } elsif ( $e->{mask} & (IN_IGNORED | IN_UNMOUNT | IN_ONESHOT | IN_DELETE_SELF) ) {
        item_to_remove_by_event( $inotify, $fullname, $e, 1 );
    }

    dump_watched( $inotify, 'actual list' ) if $ver >= 9;

    return 1;
};



items_to_watch_recursive( $dirs_to_watch );

if ( $num_to_watch != $num_watched ) {
    print "Watching only $num_watched of $num_to_watch dirs.\n";
} else {
    print "Now watching all $num_watched dirs.\n";
}


# Main event loop.
while () {
   $! = undef;
   my @events = $inotify->read;
   if ( @events > 0 ) {
       if ( %$cookie_to_rm ) {
           # Remove all IN_MOVE_FROM without IN_MOVE_TO. See assumption c).
           print 'cookie_to_rm: ' . mdump( $cookie_to_rm ) if $ver >= 10;
           foreach my $cookie ( keys %$cookie_to_rm ) {
               if ( defined $cookie_to_rm->{$cookie} ) {
                    my $fullname = $cookie_to_rm->{$cookie};
                    print "After loop cleanup - fullname '$fullname'.\n" if $ver >= 4;
                    item_to_remove_by_name( $inotify, $fullname, 0 );
                    my $items_inside_prefix = $fullname . '/';
                    item_to_remove_by_name( $inotify, $items_inside_prefix, 1 );
                    delete $cookie_to_rm->{$cookie};
               }
           }
       }

   } else {
        print "Read error: $!\n" if $ver >= 1 && $!;
   }
}
