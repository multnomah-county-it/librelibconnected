#!/usr/bin/perl
#
# ReLibConnectEd Ingestor
#
# This script is run by relibconnected.pl when an upload file is detected. It 
# takes two required parameters, the absolute path to it's configuration file, 
# config.yaml, and the absolute path to the data file to be ingested.
#
# Pragmas 
use strict;
use warnings;
use utf8;
use 5.010;

# Load modules
use File::Basename;
use Log::Log4perl qw(get_logger :levels);
use YAML::Tiny;
use Parse::CSV;
use Date::Calc qw(check_date Today leap_year Delta_Days Decode_Date_US);
use AddressFormat;
use Email::Mailer;
use Switch;
use Data::Dumper qw(Dumper);
use Unicode::Normalize;
use Email::Valid;
use Try::Tiny;
use Digest::MD5 qw(md5_hex);
use DBI;
use DBD::mysql;

our $yaml;
BEGIN {
  $yaml = YAML::Tiny->read($ARGV[0]);
  $ENV{'ILSWS_BASE_PATH'} = $yaml->[0]->{'base_path'};
}

# Do this after the BEGIN so that ILSWS gets the base path from the environment
use ILSWS;

# Valid fields in uploaded CSV files
my @district_schema = qw(student_id first_name middle_name last_name address city state zipcode dob email);
my @pps_schema      = qw(first_name middle_name last_name student_id address city state zipcode dob email);

# Some globals for storing counts
our $update_cnt = 0;
our $create_cnt = 0;
our $ambiguous_cnt = 0;

our $checksum_cnt = 0;
our $alt_id_cnt = 0;
our $email_cnt = 0;
our $id_cnt = 0;
our $dob_street_cnt = 0;

# Read configuration file passed to this script as the first parameter
our $base_path = $yaml->[0]->{'base_path'};

# Get the logging configuration from the log.conf file
Log::Log4perl->init("$base_path/log.conf");
our $log = get_logger('log');

# Set the log level: $INFO, $WARN, $ERROR, $DEBUG, $FATAL
# based on the log level in config.yaml
switch( $yaml->[0]->{'log_level'} ) {
  case 'info'  { $log->level($INFO) }
  case 'warn'  { $log->level($WARN) }
  case 'error' { $log->level($ERROR) }
  case 'debug' { $log->level($DEBUG) }
  case 'fatal' { $log->level($FATAL) }
  else         { $log->level($DEBUG) }
}

# Validate email from address before starting.
if ( &validate_email($yaml->[0]->{'smtp'}->{'from'}) eq 'null' ) {
  &error_handler("Invalid from address in configuration: $yaml->[0]->{'smtp'}->{'from'}");
}

# CSV file where we'll log updates and creates. Must match CSVFILE defined in
# log.conf!
my $csv_file = "$base_path/log/ingestor.csv";

# Mail log file which will be sent as body of report message. Must match MAILFILE
# defined in log.conf!
my $mail_log = "$base_path/log/mail.log";

# Get the path to the student data file passed to script by relibconnected.pl
my $data_file = $ARGV[1];

# Check that the data file is readable
unless ( -r $data_file ) { &error_handler("Could not read $data_file") }
my $file_size = -s $data_file;

# Log start of ingest
&logger('info', "Ingestor run on $data_file ($file_size bytes) started");

# Derive the ID and namespace of the school district from the path of the 
# data file
my $dirname = dirname($data_file);
my @parts = split /\//, $dirname;
my $district = $parts[$#parts - 1];
my $id = substr($district, -2);
my $namespace = substr($district, 0, -2);

# See if we have a configuration from the YAML file that matches the district 
# derived from the file path. If so, put the configuration in $client.
my $client = ();
my $clients = $yaml->[0]->{'clients'};
foreach my $i ( 0 .. $#{$clients} ) {
  if ( $clients->[$i]->{'namespace'} eq $namespace && $clients->[$i]->{'id'} eq $id ) {
     $client = $clients->[$i];
  }
}

# Die with an error, if we didn't find a matching configuration
unless ( defined $client->{id} ) { &error_handler("Could not find configuration for $district") };

# If we did find a configuration, let the customer know
&logger('info', "Found configuration for $district");

# Open the CVS data file supplied by calling script, relibconnected.pl
open(my $data_fh, '<', $data_file) 
  || &error_handler("Could not open data file: $data_file: $!");

# Create CSV parser
my $parser = Parse::CSV->new( handle => $data_fh, sep_char => ',', names => 1 );

# Change all field names to lower case. The @fields array is global so it may
# be used in multiple functions without passing it around.
our @fields = $parser->names;
foreach my $i ( 0 .. $#fields ) {
  $fields[$i] = lc($fields[$i]);
}
$parser->names(@fields);

# Check that the field order matches the expected schema
if ($client->{'schema'} eq 'district' ) {
  unless ( &check_schema(\@fields, \@district_schema) ) { &error_handler("Fields in $data_file don't match expected schema") }
} elsif ( $client->{'schema'} eq 'pps' ) {
  unless ( &check_schema(\@fields, \@pps_schema) ) { &error_handler("Fields in $data_file don't match expected schema") }
}

# Start the CVS file output with the column headers
my $csv = get_logger('csv');
$csv->info('"action","match","' . join('","', @district_schema) . '"');

# Connect to ILSWS. The working copy of the module ILSWS.pm is stored in 
# /usr/local/lib/site_perl. The copy in the working directory is only for
# reference.
my $token = ILSWS::ILSWS_connect;
if ( $token ) {
  &logger('info', "Login to ILSWS $yaml->[0]->{'ilsws'}->{'webapp'} successful");
} else {
  &error_handler("Login to ILSWS failed: $ILSWS::error");
}

# Connect to checksums database which we'll use to store checksums for the
# student data. By checking against the stored checksum, we can determine 
# whether the student data has changed, therefore whether we need to update
# Symphony via Web Services
my $dbh = &connect_database;

# Loop through lines of data and check for valid values. Ingest valid lines.
# The $lineno is a global so we can encorporate it into log or error messages.
our $lineno = 1;
while ( my $student = $parser->fetch ) {
  my $errors = 0;
  foreach my $key (keys %{$student}) {

    # If the student has no address (a private address), then set the address
    # to the ISOM Building.
    if ( ! $student->{'address'} && ! $student->{'city'} && ! $student->{'zipcode'} ) {
      $student->{'address'} = '205 NE Russell St';
      $student->{'city'} = 'Portland';
      $student->{'zipcode'} = '97212';
    }

    # Validate and reformat data in each field, as necessary
    my $validate = &validate_field($key, $student->{$key});

    # Log any errors, except with email, because that field is not required.
    if ( ! $validate ) {
      &logger('error', "Invalid data in line $lineno, $key: " . $student->{$key});
      $errors++;
    } else {
      $student->{$key} = $validate;
    }
  }

  if ( $errors ) { 

    # We got errors when validating this student's data, so log and skip 
    # this record
    &logger('error', "Skipping $student->{'last_name'}, $student->{'first_name'} ($student->{'student_id'} at line $lineno) due to data error(s)");

  } else {

    # Check the checksum database for changes to the data or for new data and 
    # process the student record only if necessary
    if ( &check_for_changes($student, $client, $dbh) ) {
      &process_student($token, $client, $student);
    } else {
      $checksum_cnt++;
    }
  }

  $lineno++;
}

# Disconnect from the checksums database
$dbh->disconnect;

# Close data file
close($data_fh) || &error_handler("Could not close $data_file: $!");

# Tell'em we're finished
&logger('info', "Ingestor run on $data_file finished");
&logger('info', "Statistics: $update_cnt updates, $create_cnt creates, $ambiguous_cnt ambiguous");
&logger('info', "Matches: $checksum_cnt Checksum, $alt_id_cnt Alt ID, $id_cnt ID, $email_cnt Email, $dob_street_cnt DOB and Street");

# Validate admin contact email addresses
my @addresses = split /,\s*/, $yaml->[0]->{'admin_contact'};
my @valid_addresses = ();

if ( $client->{'email_reports'} eq 'true' ) {
  my @contacts = split /,\s*/, $client->{'contact'};
  if ( @contacts ) {
    push @addresses, @contacts;
  }
}

foreach my $i (0 .. $#addresses) {
  if ( &validate_email($addresses[$i]) ne 'null' ) {
    push @valid_addresses, $addresses[$i];
  } else {
    &error_handler("Invalid email address in configuration: $addresses[$i]");
  }
}

# Prepare email to the admin contact with the mail.log and ingester.csv files as
# attachements
my $mailer = Email::Mailer->new(
  to      => join(',', @valid_addresses),
  from    => $yaml->[0]->{'smtp'}->{'from'},
  subject => "RELIBCONNECTED Ingest Report $client->{'name'} ($client->{'namespace'}$client->{'id'})",
  text    => "Log and CSV output files from RELIBCONNECT ingest.",
  attachments => [
    {
      ctype  => 'text/plain',
      source => $mail_log,
    },
    {
      ctype  => 'text/csv',
      source => $csv_file,
    },
  ],
);

try {
  # Mail the logs to the admin contact(s)
  $mailer->send;
} catch {
  &error_handler("Could not email logs: $_");
};

# Delete the mail log and the CSV file
unlink $mail_log || &error_handler("Could not delete mail.log: $!");
unlink $csv_file || &error_handler("Could not delete csv_file: $!");

# Delete the ingest data file
unlink "$data_file" || &error_handler("Could not delete data file: $!");

###############################################################################
# Subroutines
###############################################################################
#
###############################################################################
# Process a student. This is the core logic where we decide if we are going to 
# update (overlay) a record, create a new record, or log the data only due to
# multiple ambiguous matches.

sub process_student {
  my $token = shift;
  my $client = shift;
  my $student = shift;

  # Check for existing patron with same student ID in the ALT_ID field
  my %options = ( ct => 1, includeFields => 'barcode' );
  my $existing = ILSWS::patron_alt_id_search($token, "$client->{'id'}$student->{'student_id'}", \%options);

  if ( $existing ) {

    if ( $ILSWS::code != 200 ) {
      &logger('error', $ILSWS::error);

    } elsif ( $existing->{'totalResults'} == 1 && $existing->{'result'}->[0]->{'key'} ) {
        $alt_id_cnt++;
        $student->{'barcode'} = $existing->{'result'}->[0]->{'fields'}->{'barcode'}
          if defined($existing->{'result'}->[0]->{'fields'}->{'barcode'});
        &update_student($token, $client, $student, $existing->{'result'}->[0]->{'key'}, 'Alt ID', $lineno);
        $update_cnt++;
        return 1;
    }

  } else {
    &logger('error', $ILSWS::error);
  } 

  # Search for the student via email address
  if ( $student->{'email'} ne 'null' ) {

    %options = ( ct => 2, includeFields => 'barcode' );
    $existing = ILSWS::patron_search($token, 'EMAIL', $student->{'email'}, \%options);

    # If there is only one record with this student ID, overlay the record and
    # return from the subroutine. If there is more than one person using the 
    # same email address then go on to the next search.
    if ( $existing ) {
      
      if ( $ILSWS::code != 200 ) {
        &logger('error', $ILSWS::error);

      } elsif ( $existing->{'totalResults'} == 1 && $existing->{'result'}->[0]->{'key'} ) {
        $email_cnt++;
        $student->{'barcode'} = $existing->{'result'}->[0]->{'fields'}->{'barcode'}
          if defined($existing->{'result'}->[0]->{'fields'}->{'barcode'});
        &update_student($token, $client, $student, $existing->{'result'}->[0]->{'key'}, 'Email', $lineno);
        $update_cnt++;
        return 1;
      }

    } else {
      &logger('error', $ILSWS::error);
    }
  }

  # Check for existing patron with same student ID in the ID field (barcode)
  %options = ( ct => 1, includeFields => 'barcode' );
  $existing = ILSWS::patron_barcode_search($token, "$client->{'id'}$student->{'student_id'}", \%options);

  if ( $existing ) {

    if ( $ILSWS::code != 200 ) {
      &logger('error', $ILSWS::error);

    } elsif ( $existing->{'totalResults'} == 1 && $existing->{'result'}->[0]->{'key'} ) {

      # $student
      $id_cnt++;
      $student->{'barcode'} = $existing->{'result'}->[0]->{'fields'}->{'barcode'}
        if defined($existing->{'result'}->[0]->{'fields'}->{'barcode'});
      &update_student($token, $client, $student, $existing->{'result'}->[0]->{'key'}, 'ID', $lineno);
      $update_cnt++;
      return 1;
    }

  } else {

    &logger('error', $ILSWS::error);
  }

  # Search by DOB and address
  $existing = &search($token, $client, $student);

  if ( $#{$existing} == 0 ) {

    # Looks like this student may have moved
    if ( defined $existing->[0]->{'key'} ) {
      $dob_street_cnt++;
      $student->{'barcode'} = $existing->[0]->{'fields'}->{'barcode'}
        if defined($existing->[0]->{'fields'}->{'barcode'});
      &update_student($token, $client, $student, $existing->[0]->{'key'}, 'DOB and Street', $lineno);
      $update_cnt++;
    }

  } elsif ( $#{$existing} > 0 ) {

    # We got multiple matches, so reject the search results as ambiguous 
    # and report the new student data in logs. This student
    &logger('debug', qq|"AMBIGUOUS:","DOB and Street",| . &print_line($student));
    $csv->info(qq|"Ambiguous","DOB and Street",| . &print_line($student));
    $ambiguous_cnt++;

  } else {

    # All efforts to match this student failed, so create new record for them
    &create_student($token, $client, $student);
    $create_cnt++;
  }

  return 1;
}

###############################################################################
# Search ILSWS on DOB and address to match existing student

sub search {
  my $token = shift;
  my $client = shift;
  my $student = shift;

  my @results = ();
  my $csv = get_logger('csv');

  my ($year, $mon, $day) = split /-/, $student->{'dob'};
  my %options = ( ct => 1000, includeFields => 'barcode,firstName,middleName,lastName' );
  my $bydob = ILSWS::patron_search($token, 'BIRTHDATE', "${year}${mon}${day}", \%options);

  if ( $bydob->{'totalResults'} >= 1 ) {

    # If we found a person or persons with student's DOB, then we continue
    # by searching via street.
    
    # Remove punctuation from address before searching
    my $street = $student->{'address'};
    $street =~ s/#//g;
    my $bystreet = ILSWS::patron_search($token, 'STREET', $street, \%options);

    if ( $bystreet->{'totalResults'} >= 1 ) {

      # Compare the two result sets to see if we can find the same student
      # in both the DOB and street result sets
      @results = &compare_results($bydob->{'result'}, $bystreet->{'result'});

      if ( $#results >= 1 ) {

        # Now report the possible matches
        foreach my $i (0 .. $#results) {

          # Add each ambiguous record to the CSV log with the ID and name
          # information. Put the student ID in the the ID field along with the 
          # matching record ID, so the CSV can be storted appropriately. Add 
          # name and addresss from matching records.
          my $message = qq|"Ambiguous","DOB and Street",|;
          $message   .= qq|"$student->{'student_id'}, $results[$i]{'key'}",|;
          $message   .= qq|"$results[$i]{'fields'}->{'firstName'}",|;
          if ( $results[$i]{'fields'}->{'middleName'} ) {
            $message   .= qq|"$results[$i]{'fields'}->{'middleName'}",|;
          }
          $message   .= qq|"$results[$i]{'fields'}->{'lastName'}",|;
          $csv->info($message);
          $log->debug(Dumper($results[$i]));
        }
      }
    }
  }

  # Return a reference to the @results array
  return \@results;
}

###############################################################################
# Compare result sets from ILSWS searches and return array of record hashes
# where the records share the same user key

sub compare_results {
  my $set1 = shift;
  my $set2 = shift;

  my @results = ();
  my $count = 0;

  foreach my $i (@{$set1}) {
    foreach my $x (@{$set2}) {
      if ( $i->{'key'} eq $x->{'key'} ) {
        $results[$count]{'key'} = $i->{'key'};
        $results[$count]{'fields'}{'barcode'} = $i->{'fields'}->{'barcode'};
        $count++;
      }
    }
  }

  return @results;
}

###############################################################################
# Create new student record

sub create_student {
  my $token = shift;
  my $client = shift;
  my $student = shift;

  my $csv = get_logger('csv');
  my $json = JSON->new->allow_nonref;

  # Put student data into the form expected by ILSWS.
  my $new_student = &create_data_structure($student);

  # Convert the data structure into JSON
  my $student_json = $json->pretty->encode($new_student);
  &logger('debug', $student_json);

  # Remove diacritcs
  $student_json = NFKD($student_json);
  $student_json =~ s/\p{NonspacingMark}//g;

  # Set the max retries
  my $max_retries = 3;
  if ( defined $yaml->[0]->{'ilsws'}->{'max_retries'} ) {
    $max_retries = $yaml->[0]->{'ilsws'}->{'max_retries'};
  }

  my $res = '';
  my $retries = 1;
  while (! $res && $retries <= $max_retries ) {
    # Send the patron create JSON to ILSWS
    $res = ILSWS::patron_create($token, $student_json);
    if ( ! $res ) {
      &logger('error', "Failed to create $client->{'id'}$student->{'student_id'} (line $lineno) on attempt $retries: " . &print_line($student));
      &logger('error', "$ILSWS::code: $ILSWS::error");
    }
    sleep($retries);
    $retries++;
  }

  if ( $res ) {
    # We created a patron. Log the event.
    $csv->info('"Create","",' . &print_line($student));
    &logger(
      'debug', 
      "CREATE: $student->{'last_name'}, $student->{'first_name'} $student->{'student_id'} as $client->{'id'}$student->{'student_id'}"
      );
  }
}

###############################################################################
# Update existing student

sub update_student {
  my $token = shift;
  my $client = shift;
  my $student = shift;
  my $key = shift;
  my $match = shift;

  my $json = JSON->new->allow_nonref;
  my $csv = get_logger('csv');

  # Put student data into the form expected by ILSWS.
  my $new_student = &create_data_structure($student, $key);

  # Convert the data structure into JSON
  my $student_json = $json->pretty->encode($new_student);
  &logger('debug', $student_json);

  # Remove diacritcs
  $student_json = NFKD($student_json);
  $student_json =~ s/\p{NonspacingMark}//g;

  # Set the max retries
  my $max_retries = 3;
  if ( defined $yaml->[0]->{'ilsws'}->{'max_retries'} ) {
    $max_retries = $yaml->[0]->{'ilsws'}->{'max_retries'};
  }

  my $res = '';
  my $retries = 1;
  while (! $res && $retries <= $max_retries ) {
    # Send the patron update JSON to ILSWS
    $res = ILSWS::patron_update($token, $student_json, $key);
    if ( ! $res ) {
      &logger('error', "Failed to update $client->{'id'}$student->{'student_id'} (line $lineno) on attempt $retries: " . &print_line($student));
      &logger('error', "$ILSWS::code: $ILSWS::error");
    }
    sleep($retries);
    $retries++;
  }

  if ( $res ) {
    # We got a result! Yay!
    $csv->info(qq|"Update","$match",| . &print_line($student));
    &logger(
      'debug', 
      "OVERLAY: $student->{'last_name'}, $student->{'first_name'} $student->{'student_id'} as $client->{'id'}$student->{'student_id'}"
      );
  }
}

###############################################################################
# Create the datastructure for an ILSWS query to create or update a patron
# record in Symphony

sub create_data_structure {
  my $student = shift;
  my $key = shift;

  my %new_student = ();
  my $mode = '';

  if ( $key && $key =~ /^\d+$/ ) {
    $mode = 'overlay_defaults';
    $new_student{'key'} = $key;
  } else {
    $mode = 'new_defaults';
  }

  my ($year, $mon, $day) = split /-/, $student->{'dob'};

  $new_student{'resource'} = '/user/patron';

  if ( $student->{'barcode'} && $student->{'barcode'} =~ /^\d{14}$/ ) {
    $new_student{'fields'}{'barcode'} = "$student->{'barcode'}";
    $new_student{'fields'}{'alternateID'} = "$client->{'id'}$student->{'student_id'}";
  } else {
    $new_student{'fields'}{'barcode'} = "$client->{'id'}$student->{'student_id'}";
    $new_student{'fields'}{'alternateID'} = "$client->{'id'}$student->{'student_id'}";
  }

  $new_student{'fields'}{'firstName'} = $student->{'first_name'};
  if ( $student->{'middle_name'} ne 'null' ) {
    $new_student{'fields'}{'middleName'} = $student->{'middle_name'};
  }
  $new_student{'fields'}{'lastName'} = $student->{'last_name'};
  $new_student{'fields'}{'birthDate'} = $student->{'dob'};

  if ( $mode eq 'new_defaults' ) {
    $new_student{'fields'}{'pin'} = "${mon}${day}${year}";
  }

  $new_student{'fields'}{'category01'}{'resource'} = '/policy/patronCategory01';
  $new_student{'fields'}{'category01'}{'key'} = $client->{$mode}->{'user_categories'}->{'1'};

  if ( $mode eq 'new_defaults' ) {
    $new_student{'fields'}{'category02'}{'resource'} = '/policy/patronCategory02';
    $new_student{'fields'}{'category02'}{'key'} = $client->{'new_defaults'}->{'user_categories'}->{'2'};
  }

  $new_student{'fields'}{'category03'}{'resource'} = '/policy/patronCategory03';
  $new_student{'fields'}{'category03'}{'key'} = $client->{$mode}->{'user_categories'}->{'3'};

  $new_student{'fields'}{'category07'}{'resource'} = '/policy/patronCategory07';
  $new_student{'fields'}{'category07'}{'key'} = $client->{$mode}->{'user_categories'}->{'7'};

  $new_student{'fields'}{'profile'}{'resource'} = '/policy/userProfile';
  if ( &over_thirteen($student->{'dob'}) ) {
    $new_student{'fields'}{'profile'}{'key'} = $client->{$mode}->{'user_profile'};
  } else {
    $new_student{'fields'}{'profile'}{'key'} = $client->{$mode}->{'youth_profile'};
  }

  $new_student{'fields'}{'library'}{'resource'} = '/policy/library';
  $new_student{'fields'}{'library'}{'key'} = $client->{$mode}->{'home_library'};

  my %street = ();
  $street{'resource'} = '/user/patron/address1';
  $street{'fields'}{'code'}{'key'} = 'STREET';
  $street{'fields'}{'code'}{'resource'} = '/policy/patronAddress1';
  $street{'fields'}{'data'} = $student->{'address'};

  my %city_state = ();
  $city_state{'resource'} = '/user/patron/address1';
  $city_state{'fields'}{'code'}{'key'} = 'CITY/STATE';
  $city_state{'fields'}{'code'}{'resource'} = '/policy/patronAddress1';
  $city_state{'fields'}{'data'} = "$student->{'city'}, $student->{'state'}";

  my %zip = ();
  $zip{'resource'} = '/user/patron/address1';
  $zip{'fields'}{'code'}{'key'} = 'ZIP';
  $zip{'fields'}{'code'}{'resource'} = '/policy/patronAddress1';
  $zip{'fields'}{'data'} = $student->{'zipcode'};

  my %email = ();
  if ( $student->{'email'} ne 'null' ) {
    $email{'resource'} = '/user/patron/address1';
    $email{'fields'}{'code'}{'key'} = 'EMAIL';
    $email{'fields'}{'code'}{'resource'} = '/policy/patronAddress1';
    $email{'fields'}{'data'} = $student->{'email'};
  }

  $new_student{'fields'}{'address1'} = [ { %street }, { %city_state }, { %zip } ];
  if ( %email ) {
    push @{$new_student{'fields'}{'address1'}}, ( { %email } );
  }

  # Return a reference to the student data structure
  return \%new_student;
}

###############################################################################
# Calculate if age over thirteen from birthday.

sub over_thirteen {
  my $dob = shift;
  my $retval = 0;

  my ($year1, $month1, $day1) = split /-/, $dob;
  my ($year2, $month2, $day2) = Today();

  if (($day1 == 29) && ($month1 == 2) && !leap_year($year2))
    { $day1--; }

  if ( (($year2 - $year1) >  12) 
    || ( (($year2 - $year1) == 12) 
    && (Delta_Days($year2,$month1,$day1, $year2,$month2,$day2) >= 0) ) ) {

    $retval = 1;
  } 

  return $retval;
}

###############################################################################
# Log errors and exit

sub error_handler {
  my $message = shift;

  &logger('error', $message);

  exit(-1);
}

###############################################################################
# Sends log messages to multiple logs as needed. Generally, we log to 
# the permanent log and to the temporary log which will be mailed at the 
# end of the ingest. Separate commands are used to send data to the CSV file.

sub logger {
  my $level = shift;
  my $message = shift;

  # Log more information to the permanent log
  if ( $level eq 'error' ) {

    # Add the calling package and line number to errors
    my ($package, $filename, $line) = caller;
    $log->$level("$package:${line}: $message");

  } else {
    $log->$level($message);
  }
}

###############################################################################
#
# Checks if the field headings in the incoming student data file match the 
# expected names in @valid_fields

sub check_schema {
  my $fields = shift;
  my $valid_fields = shift;
  my $errors = 0;
  my $retval = 0;

  foreach my $i ( 0 .. $#{$fields} ) {
    if ( $fields->[$i] ne $valid_fields->[$i] ) {
      &logger('error', "Invalid field in position $i");
      $errors++;
    }
  }

  unless ( $errors ) { $retval = 1 }
  return $retval;
}

###############################################################################
# Produces a line of student data in comma-delimited form

sub print_line {
  my $student = shift;

  # Print out the student fields in a standard order, regardless
  # of the order they were entered in the hash.
  my $string = qq|"$student->{'student_id'}",|;
  $string   .= qq|"$student->{'first_name'}",|;
  $string   .= qq|"$student->{'middle_name'}",|;
  $string   .= qq|"$student->{'last_name'}",|;
  $string   .= qq|"$student->{'address'}",|;
  $string   .= qq|"$student->{'city'}",|;
  $string   .= qq|"$student->{'state'}",|;
  $string   .= qq|"$student->{'zipcode'}",|;
  $string   .= qq|"$student->{'dob'}",|;
  $string   .= qq|"$student->{'email'}"|;

  return $string;
}

###############################################################################
#
# Checks if there is a function to validate a particular field. If there is
# one, it runs it, passing in the value, which may be returned unchanged, 
# returned reformatted, or returned as null (in which case an error should 
# be returned by the calling code, if appropriate.)

sub validate_field {
  my $field_name = shift;
  my $value = shift;

  my $sub = "validate_$field_name";

  if ( exists &{$sub} ) {
    my $subroutine = \&{$sub};

    # Run the function to check the value
    $value = $subroutine->($value);
  }

  return $value;
}

###############################################################################
# Validates student_id as a number

sub validate_student_id {
  my $value = shift;
  my $retval = 0;

  if ( $value =~ /^\d{6}$/ ) {
    $retval = $value;
  }

  return $retval;
}

###############################################################################
# Validates zipcode as ##### or #####-####.

sub validate_zipcode {
  my $value = shift;
  my $retval = '';

  if ( $value =~ /^\d{5}$/ || $value =~ /^\d{5}-\d{4}$/ ) {
    $retval = $value;
  }

  return $retval;
}

###############################################################################
# Validates and reformats the date of birth. Accepts dates in two formats:
# MM/DD/YYYY or M/D/YYYY HH:MM:SS AM|PM

sub validate_dob {
  my $value = shift;

  my $retval = '';
  my $date = '';
  my ($year, $mon, $day);

  if ( length($value) > 10 ) {
    my @parts = split /\s/, $value;
    $date = $parts[0];
  } else {
    $date = $value;
  }

  if ( ($year, $mon, $day) = Decode_Date_US($date) ) {
    if ( check_date($year, $mon, $day) ) {
      $mon = sprintf("%02d", $mon);
      $day = sprintf("%02d", $day);
      $retval = "$year-$mon-$day";
    }
  }

  return $retval;
}

###############################################################################
# Checks for valid email address format, returns nothing if not valid

sub validate_email {
  my $value = shift;

  if ( $value ) {
    $value = Email::Valid->address($value) ? $value : 'null';
  } else {
    $value = 'null';
  }

  return $value;
}

###############################################################################
# Required first_name, max 20 characters

sub validate_first_name {
  my $value = shift;
  my $retval = '';

  if ( $value ) {
    $retval = substr($value, 0, 20);
  }

  return $retval;
}

###############################################################################
# Not required middle_name, max 20 characters. Return null if not supplied.

sub validate_middle_name {
  my $value = shift;

  if ( ! $value ) {
    $value = 'null';
  }

  return substr($value, 0, 20);
}

###############################################################################
# Required last_name, max 60 characters

sub validate_last_name {
  my $value = shift;
  my $retval = '';

  if ( $value ) {
    $retval = substr($value, 0, 60);
  }

  return $retval;
}

###############################################################################
# Use the AddressFormat.pm function to validate and reformat to USPS standards

sub validate_address {
  my $value = shift;

  return AddressFormat::format_street($value);
}

###############################################################################
# Use the AddressFormat.pm function to validate and reformat to USPS standard

sub validate_city {
  my $value = shift;

  return AddressFormat::format_city($value);
}

###############################################################################
# Use the AddressFormatpm function to validate and reformat to USPS standard

sub validate_state {
  my $value = shift;

  return AddressFormat::format_state($value);
}

###############################################################################
# Create a digest (checksum) that can be used when checking if data has
# changed. Sort the keys so that they always appear in the same order, 
# regardless of the order they were entered.

sub digest {
  my $data = shift;
  local $Data::Dumper::Sortkeys = 1;

  return md5_hex(Dumper($data));
}

###############################################################################

sub check_for_changes {
  my $student = shift;
  my $client = shift;
  my $dbh = shift;

  my $student_id = $client->{'id'} . $student->{'student_id'};

  # Default is to assume that the data has changed
  my $retval = 1;

  # Create an MD5 digest from the incoming student data
  my $checksum = &digest($student);

  my $sql = qq|SELECT chksum FROM checksums WHERE student_id = '$student_id'|;
  my $sth = $dbh->prepare($sql);
  $sth->execute() or &error_handler("Could not search checksums: $dbh->errstr()");

  my $result = $sth->fetchrow_hashref;

  if ( defined $result->{'chksum'} ) {

    # We found a checksum record so we can check to see if the new data has 
    # changed
    if ( $checksum eq $result->{'chksum'} ) {

      # The checksums are the same, so the data has not changed
      $retval = 0;

      # Log to the CSV file
      my $csv = get_logger('csv');
      $csv->info(qq|"OK","Checksum",| . &print_line($student));

    } else {

      # The incoming data has changed, so update the checksum
      $sql = qq|UPDATE checksums SET chksum = '$checksum' WHERE student_id = '$student_id'|;
      $sth = $dbh->prepare($sql);
      $sth->execute() or &error_handler("Could not update checksums: $dbh->errstr()");

      &logger('debug', "Student data changed, updating checksum database");
    }

  } else {

    # We did not find a checksum record for this student, so we should add one
    $sql = qq|INSERT INTO checksums (student_id, chksum, date_added) VALUES ('$student_id', '$checksum', CURDATE())|;
    $sth = $dbh->prepare($sql);
    $sth->execute() or &error_handler("Could add record to checksums: $dbh->errstr()");

    &logger('debug', "Inserted new record in checksum database");
  }
  $sth->finish();

  return $retval;
}

###############################################################################
# Connect to checksums database

sub connect_database {

  # Collect configuration data for database connection
  my $hostname = $yaml->[0]->{'mysql'}->{'hostname'};
  my $port     = $yaml->[0]->{'mysql'}->{'port'};
  my $database = $yaml->[0]->{'mysql'}->{'db_name'};
  my $username = $yaml->[0]->{'mysql'}->{'db_username'};
  my $password = $yaml->[0]->{'mysql'}->{'db_password'};

  # Connect to the checksums database
  my $dsn = "DBI:mysql:database=$database;host=$hostname;port=$port";
  my $dbh = DBI->connect($dsn, $username, $password, { RaiseError => 0, AutoCommit => 1} ) 
    or &error_handler("Unable to connect with $database database: $!");

  &logger('info', "Login to $database database successful");

  return $dbh;
}

###############################################################################

###############################################################################
