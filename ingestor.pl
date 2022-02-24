#!/usr/bin/perl
#
# ReLibConnectEd Ingestor
#
# This script is run by relibconnected.pl when an upload file is detected.
#
# Pragmas 
use strict;
use warnings;
use utf8;

# Load modules
use File::Basename;
use Log::Log4perl qw(get_logger :levels);
use YAML::Tiny;
use Parse::CSV;
use Date::Calc qw(check_date Today leap_year Delta_Days);
use AddressFormat;
use ILSWS;
use Email::Mailer;
use Switch;
use Data::Dumper qw(Dumper);
use Unicode::Normalize;

# Valid fields in uploaded CSV files
our @valid_fields = qw(student_id first_name middle_name last_name address city state zipcode dob email);

# Read configuration file passed to this script as the first parameter
my $config_file = $ARGV[0];
my $yaml = YAML::Tiny->read($config_file);
our $base_path = $yaml->[0]->{'base_path'};

# Get the logging configuration from the log.conf file
Log::Log4perl->init("$base_path/log.conf");
our $log = get_logger('log');

# Set the log level: $INFO, $WARN, $ERROR, $DEBUG, $FATAL
# based on the log level in config.yaml
switch( $yaml->[0]->{'log_level'} ) {
  case 'info' { $log->level($INFO) }
  case 'warn' { $log->level($WARN) }
  case 'error' { $log->level($ERROR) }
  case 'debug' { $log->level($DEBUG) }
  case 'fatal' { $log->level($FATAL) }
  else        { $log->level($DEBUG) }
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
my $clients = $yaml->[0]->{clients};
foreach my $i ( 0 .. $#{$clients} ) {
  if ( $clients->[$i]->{namespace} eq $namespace && $clients->[$i]->{id} eq $id ) {
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

# Start the CVS file output with the column headers
my $csv = get_logger('csv');
$csv->info('"action","match","' . join('","', @valid_fields) . '"');

# Check that we're receiving the right fields in the right order
my @fields = $parser->fields;
unless ( &check_schema(@fields) ) { &error_handler("Fields in $data_file don't match expected schema") }

# Connect to ILSWS. The working copy of the module ILSWS.pm is stored in 
# /usr/local/lib/site_perl. The copy in the working directory is only for
# reference.
my $token = ILSWS::ILSWS_connect;
if ( $token ) {
  &logger('info', "Login to ILSWS successful");
} else {
  &error_handler("Login to ILSWS failed: $ILSWS::error");
}

# Loop through lines of data and check for valid values. Ingest valid lines.
my $lineno = 1;
while ( my $student = $parser->fetch ) {
  my $errors = 0;
  foreach my $key (keys %{$student}) {

    # Validate and reformat data in each field, as necessary
    my $validate = &validate_field($key, $student->{$key});

    # Log any errors
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
    &logger('error', "Skipping $student->{'last_name'}, $student->{'first_name'} ($student->{'student_id'}) due to data error(s)");

  } else {

    # Process the student record
    &process_student($token, $client, $student);
  }

  $lineno++;
}

# Close data file
close($data_fh) || &error_handler("Could not close $data_file: $!");

# Tell'em we're finished
&logger('info', "Ingestor run on $data_file finished");

# Send an email to the admin contact with the mail.log and ingester.csv files as
# attachements
Email::Mailer->send(
  to      => $yaml->[0]->{'admin_contact'},
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
  my $existing = ILSWS::patron_alt_id_search($token, "$client->{'id'}$student->{'student_id'}", 1);

  if ( $existing->{'totalResults'} == 1 ) {

    # We found a student, so overlay (update) and return from this subroutine
    if ( defined $existing->{'result'}->[0]->{'key'} ) {
      &update_student($token, $client, $student, $existing->{'result'}->[0]->{'key'}, 'Alt ID');
    } else {
      &error_handler("No key found in $existing");
    }
    return 1;
  } 

  # Search for the student via email address
  if ( $student->{'email'} ne 'null' ) {

    $existing = ILSWS::patron_search($token, 'EMAIL', $student->{'email'}, 2);

    # If there is only one record with this student ID, overlay the record and
    # return from the subroutine. If there is more than one person using the 
    # same email address then go on to the next search.
    if ( $existing->{'totalResults'} == 1 ) {

      if ( defined $existing->{'result'}->[0]->{'key'} ) {
        &update_student($token, $client, $student, $existing->{'result'}->[0]->{'key'}, 'Email');
      } else {
        &error_handler("No key found in $existing");
      }
      return 1;
    }
  }

  # Search by DOB and address
  $existing = &search($token, $client, $student);

  if ( $#{$existing} == 0 ) {

    # Looks like this student may have moved
    if ( defined $existing->[0]->{'key'} ) {
      &update_student($token, $client, $student, $existing->[0]->{'key'}, 'DOB and Street');
    } else {
      &error_handler("No key found in $existing");
    }

  } elsif ( $#{$existing} > 0 ) {

    # We got multiple matches, so reject the search results as ambiguous 
    # and report the new student data in logs. This student
    &logger('debug', qq|"AMBIGUOUS:","DOB and Street",| . &print_line($student));
    $csv->info(qq|"Ambiguous","DOB and Street",| . &print_line($student));

  } else {

    # All efforts to match this student failed, so create new record for them
    &create_student($token, $client, $student);
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
  my $bydob = ILSWS::patron_search($token, 'BIRTHDATE', "${year}${mon}${day}", 1000);

  if ( $bydob->{'totalResults'} >= 1 ) {

    # If we found a person or persons with student's DOB, then we continue
    # by searching via street.
    my $bystreet = ILSWS::patron_search($token, 'STREET', $student->{'address'}, 1000);

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
          $message   .= qq|"$client->{'id'}$student->{'student_id'}, $results[$i]{'key'}",|;
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

  foreach my $i (@{$set1}) {
    foreach my $x (@{$set2}) {
      if ( $i->{'key'} eq $x->{'key'} ) {
        push @results, $i;
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

  # Send the patron JSON to ILSWS
  my $res = ILSWS::patron_create($token, $student_json);

  if ( $res ) {

    # We created a patron. Log the event.
    $csv->info('"Create","",' . &print_line($student));
    &logger(
      'debug', 
      "CREATE: $student->{'last_name'}, $student->{'first_name'} $student->{'student_id'} as $client->{'id'}$student->{'student_id'}"
      );

  } else {

    # Whoops!
    &logger('error', "Failed to create $client->{'id'}$student->{'student_id'}: " . &print_line($student));
    &logger('error', $ILSWS::error);
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

  # Send the data to ILSWS
  my $res = ILSWS::patron_update($token, $student_json, $key);

  if ( $res ) {

    $csv->info(qq|"Update","$match",| . &print_line($student));
    &logger(
      'debug', 
      "OVERLAY: $student->{'last_name'}, $student->{'first_name'} $student->{'student_id'} as $client->{'id'}$student->{'student_id'}"
      );

  } else {

    &logger('error', "Failed to update $client->{'id'}$student->{'student_id'}: " . &print_line($student));
    &logger('error', $ILSWS::error);
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
    $mode = 'new_defaults';
    $new_student{'key'} = $key;
  } else {
    $mode = 'overlay_defaults';
  }

  my ($year, $mon, $day) = split /-/, $student->{'dob'};

  $new_student{'resource'} = '/user/patron';
  $new_student{'fields'}{'barcode'} = "$client->{'id'}$student->{'student_id'}";
  $new_student{'fields'}{'firstName'} = $student->{'first_name'};
  if ( $student->{'middle_name'} ne 'null' ) {
    $new_student{'fields'}{'middleName'} = $student->{'middle_name'};
  }
  $new_student{'fields'}{'lastName'} = $student->{'last_name'};
  $new_student{'fields'}{'birthDate'} = $student->{'dob'};
  $new_student{'fields'}{'pin'} = "${mon}${day}${year}";

  if ( $mode eq 'new_defaults' ) {
    $new_student{'fields'}{'category01'}{'resource'} = '/policy/patronCategory01';
    $new_student{'fields'}{'category01'}{'key'} = $client->{'new_defaults'}->{'user_categories'}->{'1'};

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
  $new_student{'fields'}{'library'}{'key'} = $client->{'new_defaults'}->{'home_library'};

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
  my @fields = @_;
  my $errors = 0;
  my $retval = 0;

  foreach my $i ( 0 .. $#fields ) {
    if ( $fields[$i] ne $valid_fields[$i] ) {
      &logger('error', "Invalid field in position $i") unless $fields[$i] eq $valid_fields[$i];
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

  my $string = '';
  foreach my $key (@valid_fields) {
    $string .= qq|"$student->{$key}",|;
  }
  chop $string;

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
  my $retval = 0;

  if ( $value =~ /^\d{5}$/ || $value =~ /^\d{5}-\d{4}$/ ) {
    $retval = $value;
  }

  return $retval;
}

###############################################################################
# Validates and reformats the date of birth
# moment(record.dob, 'MM/DD/YYYY').format('YYYY-MM-DD')

sub validate_dob {
  my $value = shift;
  my $retval = 0;

  my ($mon, $day, $year) = split /\//, $value;
  if ( check_date($year, $mon, $day) ) {
    $retval = "$year-$mon-$day";
  }

  return $retval;
}

###############################################################################
# TO DO: better validation. Right now, only checks for @ symbol

sub validate_email {
  my $value = shift;

  if ( ! $value ) {
    $value = 'null';
  } elsif ( $value !~ /\@/ ) {
    $value = 0;
  }

  return $value;
}

###############################################################################
# Required first_name, max 20 characters

sub validate_first_name {
  my $value = shift;
  my $retval = 0;

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
  my $retval = 0;

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
