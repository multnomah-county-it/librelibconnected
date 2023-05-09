#!/usr/bin/perl

# This script creates the directory structure into which a school district 
# may upload data files. It takes a YAML config file containing the district
# configuration information as it's only parameter.
#
# To add a new district, edit the ../config.yaml, then run this script:
# sudo ./create_new_user.pl ../config.yaml

use strict;
use warnings;
use utf8;
use 5.010;

# Check if we're running as roon
die "Must run as root" unless ( $> == 0 );

# Load modules
use YAML::Tiny;

# Make sure we have an sftponly group
eval { system("groupadd -f sftponly"); };

my $yaml = YAML::Tiny->read($ARGV[0]);

my $client = ();
my $clients = $yaml->[0]->{'clients'};
my $service_account = $yaml->[0]->{'service_account'};

foreach my $i ( 0 .. $#{$clients} ) {

  if ( $clients->[$i]->{'id'} ) {
    $client = $clients->[$i];

    my $nid = $client->{'namespace'} . $client->{'id'};
    my ($name, $passwd, $uid, $gid, $quota, $comment, $gcos, $dir, $shell) = getpwnam ($nid);

    if ( ! $name ) { 

      print "Creating user $nid\n";

      my $incoming_path = $yaml->[0]->{'incoming_path'};
      my $home_dir = "$incoming_path/$nid";
      my $incoming_dir = "$home_dir/incoming";
      my $ssh_dir = "$home_dir/.ssh";
      my $key_file = "$ssh_dir/authorized_keys";
      my $key = $client->{'authorized_key'};

      my @shell_commands = (
        [qq(/usr/sbin/adduser --gecos '' --disabled-password --home $home_dir --shell /usr/sbin/nologin $nid)],
        [qq(/usr/bin/chown $nid:$nid $home_dir)],
        [qq(/usr/bin/chmod a+rx $home_dir)],
        [qq(/usr/bin/mkdir -p $incoming_dir)],
        [qq(/usr/bin/chmod a+rx $incoming_dir)],
        [qq(/usr/bin/chown $nid:$service_account $incoming_dir)],
        [qq(/usr/bin/chmod g+ws $incoming_dir)],
        [qq(/usr/bin/mkdir -p $ssh_dir)],
        [qq(/usr/bin/echo $key > $key_file)],
        [qq(/usr/bin/chmod 700 $ssh_dir)],
        [qq(/usr/bin/chmod 600 $key_file)],
        [qq(/usr/bin/chown -R $nid:$nid $ssh_dir)],
        [qq(/usr/sbin/usermod -a -G sftponly $nid)],
        );
   
      foreach my $i ( 0 .. $#shell_commands ) {
        print @{$shell_commands[$i]}, "\n";
        system(@{$shell_commands[$i]}) == 0 or die "Could not run command: @{$shell_commands[$i]}";
      }

      print "User created successfuly\n";
    }
  }
}

