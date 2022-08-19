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
 
my $sql = qq|SELECT date_added FROM checksums|;
my $sth = $dbh->prepare($sql);
$sth->execute() or die "Could not delete from checksums";

my %dates = ();
while (my $hashref = $sth->fetchrow_hashref) {
  $dates{$hashref->{date_added}}++;
}

# Finish up and disconnect
$sth->finish();
$dbh->disconnect();

my $total = 0;
foreach my $date (sort keys %dates) {
  print "$date: ", $dates{$date}, "\n";
  $total = $total + $dates{$date};
}
print "Total: ", $total, "\n";

