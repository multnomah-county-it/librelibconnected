#!/usr/bin/perl
#
use strict;
use warnings;
use utf8;
use File::Copy;

my $path = '/opt/librelibconnected';
my $run_path = "$path/run";
my $log_path = "$path/log";
my $mailer = '/usr/bin/mailx';
my $mail_template = '/opt/librelibconnected/bin/stuck_clear.txt';

if ( -e "$run_path/ingestor.flg" ) {
  my $file_age = -M "$run_path/ingestor.flg";
  if ( $file_age >= 0.17 ) {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
    my $timestamp = "${mon}_${mday}_" . sprintf("%02d_%02d_%02d", $hour, $min, $sec);
    move($log_path . 'mail.log', "$path/mail_log_$timestamp" . '.log');
    move($log_path . 'ingestor.csv', "$path/ingestor_csv_$timestamp" . '.csv');
    unlink("$run_path/ingestor.flg");
    system(qq($mailer -r john.houser\@multco.us -s "LIBCONNECTED ERROR: $path" john.houser\@multco.us < $mail_template)) == 0 || die "Died on system comma
nd";
  }
}
