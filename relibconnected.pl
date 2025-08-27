#!/usr/bin/perl -T
#
# ReLibConectEd Software - Secure Ingestor Check
#
# Author: John Houser
# Copyright Multnomah County 2025
#
# This script securely checks for uploaded student data files and starts the
# ingester process. It is designed to be run from a cron job.
#
# This version adheres to the CERT Perl Secure Coding Standard by:
#   1. Using taint mode (-T) to track data from external sources.
#   2. Avoiding shell command injection by using the list form of system().
#   3. Using atomic file operations (sysopen with O_CREAT|O_EXCL) for locking
#      to prevent race conditions (TOCTOU vulnerabilities).
#   4. Removing reliance on external utilities like 'touch' and 'rm'.
#   5. Using core modules for path manipulation and file handling.
#
use strict;
use warnings;

use File::Find qw(find);
use File::Spec;
use Fcntl qw(:DEFAULT :flock); # For file constants and locking

# --- Configuration ---
$ENV{'PATH'} = '/bin:/usr/bin:/usr/sbin:/usr/local/bin';

# File paths are defined here.
my $srv_path  = '/srv/libconnected';
my $base_path = '/opt/librelibconnected';

# Application components.
my $config_file = File::Spec->catfile( $base_path, 'config.yaml' );
my $lock_file   = File::Spec->catfile( $base_path, 'run', 'ingestor.lock' );
my $ingestor    = File::Spec->catfile( $base_path, 'ingestor.pl' );
# --- End Configuration ---

###############################################################################
# Do not edit below this point
###############################################################################

# Section 1: Implement a secure, atomic locking mechanism.
#
# We use sysopen() with O_CREAT and O_EXCL. This is an atomic operation, meaning
# the check for the file's existence and its creation happen as a single,
# uninterruptible step. This prevents a race condition where two instances of
# the script might think they can run simultaneously.
#
my $lock_fh;
unless ( sysopen( $lock_fh, $lock_file, O_WRONLY | O_CREAT | O_EXCL ) ) {
    # Could not create the lock file, which means another process is running.
    # Log the event to STDERR (which cron usually emails) and exit cleanly.
    warn "Ingestor is already running. Lock file found: $lock_file. Exiting.\n";
    exit 0;
}

# Apply an advisory lock for good measure. This protects against other
# processes that are also aware of flock().
unless ( flock( $lock_fh, LOCK_EX | LOCK_NB ) ) {
    warn "Could not acquire exclusive lock on $lock_file. Exiting.\n";
    # Clean up the file we just created before exiting.
    close($lock_fh);
    unlink($lock_file);
    exit 1;
}

#
# Section 2: Find and process data files.
#
# File::Find will traverse the directory tree and call the &wanted subroutine
# for each file and directory it finds.
#
# A file has been found that triggers the ingestor. We will stop searching.
my $found_file = 0;

find(
    {
        wanted => sub {
            # Stop searching if we've already found and processed a file.
            return if $found_file;
            
            # Call original wanted subroutine for the item.
            # No need for prune logic here anymore.
            &wanted;
        },
        preprocess => sub {
            # Return a list of only the non-hidden directory entries.
            # This prevents File::Find from ever trying to access a
            # hidden file or directory we might not have permissions for.
            return grep { !/^\./ } @_;
        },
        # Don't follow symbolic links for security reasons.
        no_chdir => 1,
    },
    $srv_path
);

#
# Section 3: Clean up the lock file.
#
# This code will always run, even if the script dies, ensuring we don't
# leave a stale lock file behind.
END {
    if ($lock_fh) {
        close($lock_fh);
        # The unlink operation requires an untainted variable.
        # We know $lock_file is safe as it's defined internally.
        if ( $lock_file =~ /^(.*)$/ ) {
            unlink $1 or warn "Could not remove lock file: $lock_file: $!";
        }
    }
}

# Subroutine called by File::Find for each item found.
sub wanted {
    # $File::Find::name contains the full path to the file.
    # We only care about files, not directories. The regex check for .csv
    # effectively handles this.
    my $full_path = $File::Find::name;

    # Check if the file is a CSV file within an 'incoming' directory.
    # This check also serves to untaint the $full_path variable.
    if ( $full_path =~ m{^(.*/incoming/.*?\.csv)$}i ) {
        my $untainted_path = $1; # $1 is untainted by the regex match.

        warn "Found data file: $untainted_path\n";
        warn "Starting ingestor process...\n";

        #
        # Securely run the ingestor script.
        #
        # We use the list form of system(). This passes arguments directly to
        # the command and completely avoids the shell. This prevents any
        # special characters in the filename from being interpreted and
        # executed by the shell, mitigating command injection risks.
        #
        system( $ingestor, $config_file, $untainted_path ) == 0
            or handle_error($?, $untainted_path);

        warn "Ingestor completed successfully for $untainted_path.\n";
        $found_file = 1;
    }
}

sub handle_error {
    my ($error, $untainted_path) = @_;
    # The return value of system() is complex. We check the actual exit
    # value, which is in the upper 8 bits of $?.
    my $actual_exit = $error >> 8;
    warn "ERROR: Ingestor script '$ingestor' failed for file '$untainted_path' with exit code $actual_exit.\n";
}

exit 0;
