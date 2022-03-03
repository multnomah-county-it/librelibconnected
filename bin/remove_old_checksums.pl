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
 
my $sql = qq|DELETE FROM checksums WHERE date_added > CURDATE() + 90|;
my $sth = $dbh->prepare($sql);
$sth->execute() or die "Could not delete from checksums";

# Finish up and disconnect
$sth->finish();
$dbh->disconnect();
