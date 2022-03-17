#!/usr/bin/perl
#
# ReLibConectEd
#
# John Houser
# john.houser@multco.us
# 
# This script checks for uploaded student data files in $srv_path and starts 
# the ingester process. Run this script via cron job, as the libconnected 
# user, every five minutes or so.
#
use strict;
use File::Find;

# File paths. Edit if you move this application or the path to search for 
# data files to ingest.
my $srv_path = '/srv/libconnected';
my $base_path = '/opt/relibconnected';

# Don't change these unless you need to.
my $config_file = "$base_path/config.yaml";
my $flag_file = "$base_path/run/ingestor.flag";
my $ingestor = "$base_path/ingestor.pl";

# Standard utilities. Check to make sure these exist.
my $touch = '/usr/bin/touch';
my $rm = '/usr/bin/rm';

###############################################################################
# Do not edit below this point
###############################################################################

# Change to the $base_path so that ILSWS.pm gets the correct working dir.
chdir $base_path;

# Check if a flag file exists, indicating that an ingest is already in progress.
if ( -e $flag_file ) {

  # Found a flag file indicating an ingest is in progress, so exit without 
  # doing anything.
  exit(1);
}

# Check incoming path for uploaded data files. Find returns all files in 
# the $srv_path and passes them to the wanted subroutine as $_.
find(\&wanted, $srv_path);

sub wanted {

  # Is this a CSV file in an incoming dir?
  if ( $File::Find::dir =~ /incoming$/ && $_ =~ /\.csv$/ ) {

    # Found a data file. Set the flag indicating an ingest is in progess.
    system("$touch $flag_file") == 0 || die "ERROR: Could not create flag file: $flag_file";

    # Run the ingestor script. We do not pass the file found as a parameter
    # because the $ingestor will do it's own check for upload files and 
    # potentially load more than one.
    system("$ingestor $config_file $File::Find::dir/$_") == 0 || die "ERROR: $ingestor failed";

    # Delete the flag file.
    system("$rm $flag_file") == 0 || die "ERROR: Could not remove $flag_file";
  }
}
