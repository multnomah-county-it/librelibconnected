#!/usr/bin/perl
#
use strict;
use warnings;
use utf8;
use File::Copy;

my $path = '/opt/relibconnected';
my $run_path = "$path/run";
my $log_path = "$path/log";

if ( -e "$run_path/ingestor.flg" ) {
  my $file_age = -M "$run_path/ingestor.flg";
  if ( $file_age >= 0.17 ) {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
    my $timestamp = "${mon}_${mday}_" . sprintf("%02d_%02d_%02d", $hour, $min, $sec);
    move($log_path . 'mail.log', "$path/mail_log_$timestamp" . '.log');
    move($log_path . 'ingestor.csv', "$path/ingestor_csv_$timestamp" . '.csv');
    unlink("$run_path/ingestor.flg");
  }
}
