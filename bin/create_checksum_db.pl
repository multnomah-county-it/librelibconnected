#!/usr/bin/perl
#
use strict;
use warnings;
use utf8;

use YAML::Tiny;
use DBI;
use DBD::mysql;

die "Syntax: $0 CONFIG_FILE DB_ROOT_PASSWORD\n" unless ( $ARGV[0] && $ARGV[1] );
if ( ! -r $ARGV[0] ) {
  print STDERR "Config file not readable\n";
  die "Syntax: $0 CONFIG_FILE DB_ROOT_PASSWORD\n";
}

# Read configuration file passed to this script as the first parameter
my $yaml = YAML::Tiny->read($ARGV[0]);
my $hostname = $yaml->[0]->{'mysql'}->{'hostname'};
my $port = $yaml->[0]->{'mysql'}->{'port'};
my $database = $yaml->[0]->{'mysql'}->{'db_name'};
my $username = $yaml->[0]->{'mysql'}->{'db_username'};
my $password = $yaml->[0]->{'mysql'}->{'db_password'};

unless ( $hostname && $port && $database && $username && $password ) { die "Missing element in configuration file\n" }

# Prepare to connect
my $dsn = "DBI:mysql:host=$hostname;port=$port";

# Connect with the database server
my $dbh = DBI->connect($dsn, 'root', "$ARGV[1]");

# Create the database
my $sql = qq|CREATE DATABASE IF NOT EXISTS $database CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci|;
my $sth = $dbh->prepare($sql);
$sth->execute() or die "Could not create database: $dbh->errstr()";

$sth = $dbh->prepare("USE $database");
$sth->execute() or die "Could not change to new database: $dbh->errstr()";

# Create the libconnected user and grant priviledges to the database
$sql = qq|CREATE USER IF NOT EXISTS '$username'\@'$hostname' IDENTIFIED BY '$password'|;
$sth = $dbh->prepare($sql);
$sth->execute() or die "Could not create user $username: $dbh->errstr()";

$sql = qq|GRANT ALL on $database.* TO '$username'\@'$hostname'|;
$sth = $dbh->prepare($sql);
$sth->execute() or die "Could not grant permissions to $username: $dbh->errstr()";

$sql = qq|flush privileges|;
$sth = $dbh->prepare($sql);
$sth->execute();

# Finish and disconnect as root
$sth->finish();
$dbh->disconnect();

# Connect to the new database as the new user
$dsn = "DBI:mysql:database=$database;host=$hostname;port=$port";
$dbh = DBI->connect($dsn, $username, $password);

# Create the database structure
$sql = qq|CREATE TABLE IF NOT EXISTS checksums (
    student_id INT PRIMARY KEY, 
    chksum char(32) NOT NULL, 
    date_added DATE NOT NULL
    )|;
$sth = $dbh->prepare($sql);
$sth->execute() or die "Could not create table checksums: $dbh->errstr()";

# Finish up and disconnect
$sth->finish();
$dbh->disconnect();
