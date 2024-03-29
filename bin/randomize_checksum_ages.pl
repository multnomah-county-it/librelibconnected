#!/usr/bin/perl
#
use strict;
use warnings;
use utf8;

use DBI;
use DBD::mysql;
use YAML::Tiny;

die "Syntax: $0 CONFIG_FILE\n" unless ( -r $ARGV[0] );

# Read configuration file passed to this script as the first parameter
my $yaml = YAML::Tiny->read($ARGV[0]);
my $hostname = $yaml->[0]->{'mysql'}->{'hostname'};
my $port = $yaml->[0]->{'mysql'}->{'port'};
my $database = $yaml->[0]->{'mysql'}->{'db_name'};
my $username = $yaml->[0]->{'mysql'}->{'db_username'};
my $password = $yaml->[0]->{'mysql'}->{'db_password'};
my $max_checksum_age = $yaml->[0]->{'mysql'}->{'max_checksum_age'};

unless ( $hostname && $port && $database && $username && $password ) { die "Missing element in configuration file" }

# Connect to the new database as the new user
my $dsn = "DBI:mysql:database=$database;host=$hostname;port=$port";
my $dbh = DBI->connect($dsn, $username, $password);

my $sql = qq|SELECT student_id FROM checksums|;
my $sth = $dbh->prepare($sql);
$sth->execute() or die "Could not select date_added";

my $count = 0;
while ( my $hashref = $sth->fetchrow_hashref ) {

  # Get a random number between 0 and 7 
  my $random = int(rand(30));
  my $sql = '';

  # Increase or decrease the date added by some number between 0 and 7
  if ( $count % 2 ) {
    $sql = qq|UPDATE checksums SET date_added = (DATE_ADD(date_added, INTERVAL $random day)) WHERE student_id = $hashref->{'student_id'}|;
  } else {
    $sql = qq|UPDATE checksums SET date_added = (DATE_ADD(date_added, INTERVAL -$random day)) WHERE student_id = $hashref->{'student_id'}|;
  }
  print "$sql\n";

  my $sth = $dbh->prepare($sql);
  $sth->execute() or die "Could not update checksums";
  $sth->finish();

  $count++;
}

# Finish up and disconnect
$sth->finish();
$dbh->disconnect();
