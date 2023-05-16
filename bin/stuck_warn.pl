#!/usr/bin/perl
#
use strict;
use File::Find;

my $path = '/srv/libconnected';
my $mailer = '/usr/bin/mailx';
my $mail_template = '/opt/librelibconnected/bin/stuck_warn.txt';
my $flag = '/opt/librelibconnected/bin/stuck.flag';
my $touch = '/usr/bin/touch';
my $rm = '/usr/bin/rm';

if ( -e $flag ) {
  if ( -M $flag >= 1 ) {
    system("$rm $flag") == 0 || die "Could not remove flag file: $flag";
  }
}

find(\&wanted, $path);

sub wanted {
  # Is this a CSV file in an incoming dir?
  if ( $File::Find::dir =~ /incoming$/ && $_ =~ /\.csv$/ ) {

    # How old is the file in seconds?
    my $age = 86400 * -M $_;
    if ( ($age / 60) > 90 ) {

      if ( ! -e $flag ) {
        # The file is older than 90 minutes: send a message
        system(qq($mailer -r john.houser\@multco.us -s "LIBCONNECTED WARN: $path" john.houser\@multco.us < $mail_template)) == 0 || die "Died on system command";
        system("$touch $flag") == 0 || die "Could not create flag file: $flag";
      }
    }
  }
}
