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

# Load CPAN modules
use File::Basename;
use File::Copy qw(copy);
use Log::Log4perl qw(get_logger :levels);
use YAML::Tiny;
use Parse::CSV;
use Date::Calc qw(check_date Today leap_year Delta_Days Decode_Date_US);
use Email::Mailer;
use Switch;
use Data::Dumper qw(Dumper);
use Unicode::Normalize;
use Email::Valid;
use Try::Tiny;
use Digest::MD5 qw(md5_hex);
use DBI;
use DBD::mysql;

# Load local modules
use AddressFormat;
use DataHandler;

our $yaml;
BEGIN {
  $yaml = YAML::Tiny->read($ARGV[0]);
  $ENV{'ILSWS_BASE_PATH'} = $yaml->[0]->{'base_path'};
}

# Do this after the BEGIN so that ILSWS gets the base path from the environment
use ILSWS $yaml->[0]->{'base_path'};

# Valid fields in uploaded CSV files
our @district_schema = qw(barcode firstName middleName lastName street city state zipCode birthDate email);
our @pps_schema      = qw(firstName middleName lastName barcode street city state zipCode birthDate email);

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
#
# This hash converts incoming field names to those expected by Symphony
# and used in the config.yaml file.
my %symphony_names = (
  student_id => 'barcode',
  first_name => 'firstName',
  middle_name => 'middleName',
  last_name => 'lastName',
  address => 'street',
  city => 'city',
  state => 'state',
  zipcode => 'zipCode',
  dob => 'birthDate',
  email => 'email',
  );

our @fields = $parser->names;
foreach my $i ( 0 .. $#fields ) {
  $fields[$i] = $symphony_names{lc($fields[$i])};
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
our $lineno = 0;
while ( my $student = $parser->fetch ) {
  my $errors = 0;
  foreach my $field (keys %{$student}) {

    # Validate data in each field as configured in config.yaml
    my $value = &validate_field($field, $student->{$field}, $client);

    # Log any errors, except with email, because that field is not required.
    if ( ! $value ) {
      &logger('error', "Invalid data in line $lineno, $field: " . $student->{$field});
      $errors++;
    } else {
      $student->{$field} = $value;
    }
  }

  if ( $errors ) { 

    # We got errors when validating this student's data, so log and skip 
    # this record
    &logger('error', "Skipping $student->{'lastName'}, $student->{'firstName'} ($student->{'barcode'} at line $lineno) due to data error(s)");

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

# Temporary for diagnosis
if ( $client->{'namespace'} eq 'pps' && $client->{'id'} eq '01' ) {
  copy($mail_log, '/opt/relibconnected/sample_data/pps01-mail.log');
  copy($csv_file, '/opt/relibconnected/sample_data/pps01-ingest.csv');
}

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
  my $existing = ILSWS::patron_alt_id_search($token, "$client->{'id'}$student->{'barcode'}", \%options);

  if ( $existing ) {

    if ( $ILSWS::code != 200 ) {
      &logger('error', $ILSWS::error);

    } elsif ( $existing->{'totalResults'} == 1 && $existing->{'result'}->[0]->{'key'} ) {
        $alt_id_cnt++;
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
  $existing = ILSWS::patron_barcode_search($token, "$client->{'id'}$student->{'barcode'}", \%options);

  if ( $existing ) {

    if ( $ILSWS::code != 200 ) {
      &logger('error', $ILSWS::error);

    } elsif ( $existing->{'totalResults'} == 1 && $existing->{'result'}->[0]->{'key'} ) {

      # $student
      $id_cnt++;
      &update_student($token, $client, $student, $existing->{'result'}->[0]->{'key'}, 'ID', $lineno);
      $update_cnt++;
      return 1;
    }

  } else {

    &logger('error', $ILSWS::error);
  }

  # Search by DOB and street
  $existing = &search($token, $client, $student);

  if ( $#{$existing} == 0 ) {

    # Looks like this student may have moved
    if ( defined $existing->[0]->{'key'} ) {
      $dob_street_cnt++;
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
# Search ILSWS on DOB and street to match existing student

sub search {
  my $token = shift;
  my $client = shift;
  my $student = shift;

  my @results = ();
  my $csv = get_logger('csv');

  my ($year, $mon, $day) = split /\-/, &transform_birthDate($student->{'birthDate'}, $client, $student);
  my %options = (
    ct => 20, 
    includeFields => 'barcode,firstName,middleName,lastName'
    );
  my $bydob = ILSWS::patron_search($token, 'BIRTHDATE', "${year}${mon}${day}", \%options);

  if ( $bydob && defined($bydob->{'totalResults'}) && $bydob->{'totalResults'} >= 1 ) {

    # If we found a person or persons with student's DOB, then we continue
    # by searching via street.
    
    # Remove punctuation from street before searching
    my $street = $student->{'street'};
    $street =~ s/#//g;
    my $bystreet = ILSWS::patron_search($token, 'STREET', $street, \%options);

    if ( $bystreet && defined($bystreet->{'totalResults'}) && $bystreet->{'totalResults'} >= 1 ) {

      # Compare the two result sets to see if we can find the same student
      # in both the DOB and street result sets
      @results = &compare_results($bydob->{'result'}, $bystreet->{'result'});

      if ( $#results >= 1 ) {

        # Now report the possible matches
        foreach my $i (0 .. $#results) {

          # Add each ambiguous record to the CSV log with the ID and name
          # information. Put the student ID in the the ID field along with the 
          # matching record ID, so the CSV can be storted appropriately. Add 
          # name and streets from matching records.
          my $message = qq|"Ambiguous","DOB and Street",|;
          $message   .= qq|"$student->{'barcode'}, $results[$i]{'key'}",|;
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
      if ( $i && $x ) {
        if ( $i->{'key'} eq $x->{'key'} ) {
          $results[$count]{'key'} = $i->{'key'};
          $results[$count]{'fields'}{'barcode'} = $i->{'fields'}->{'barcode'};
          $count++;
        }
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
  my $new_student = &create_data_structure($token, $student, $client);
  print Dumper($new_student);

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
      &logger('error', "Failed to create $student->{'barcode'} (line $lineno) on attempt $retries: " . &print_line($student));
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
      "CREATE: $student->{'lastName'}, $student->{'firstName'} $student->{'barcode'} as $student->{'barcode'}"
      );
  }
}

###############################################################################
# Check if value in array

sub in_array {
    my ($arr, $search_for) = @_;
    foreach my $value (@$arr) {
        return 1 if $value eq $search_for;
    }
    return 0;
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
  my $new_student = &create_data_structure($token, $student, $client, $key);
  print Dumper($new_student);

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
      &logger('error', "Failed to update $student->{'barcode'} (line $lineno) on attempt $retries: " . &print_line($student));
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
      "OVERLAY: $student->{'lastName'}, $student->{'firstName'} $student->{'barcode'} as $student->{'barcode'}"
      );
  }
}

###############################################################################
# Create the datastructure for an ILSWS query to create or update a patron
# record in Symphony

sub create_data_structure {
  my $token = shift;
  my $student = shift;
  my $client = shift;
  my $key = shift;

  # Hash to associate resources with field names. Only needed for resources,
  # address elements, and categories, not strings
  my %resource = (
    'category01' => 'patronCategory01',
    'category02' => 'patronCategory02',
    'category03' => 'patronCategory03',
    'category04' => 'patronCategory04',
    'category05' => 'patronCategory05',
    'category06' => 'patronCategory06',
    'category07' => 'patronCategory07',
    'category08' => 'patronCategory08',
    'category09' => 'patronCategory09',
    'category10' => 'patronCategory10',
    'category11' => 'patronCategory11',
    'category12' => 'patronCategory12',
    'library'    => 'library',
    'profile'    => 'userProfile',
    'street'     => 'STREET',
    'cityState'  => 'CITY/STATE',
    'zipCode'    => 'ZIP',
    'email'      => 'EMAIL',
    );

  # Determine the mode
  my $mode = $key && $key =~ /^\d+$/ ? 'overlay' : 'new';

  my %new_student = ();
  $new_student{'resource'} = '/user/patron';
  $new_student{'fields'}{'address1'} = (); 

  my $existing = 0;
  if ( $mode eq 'overlay' ) {
    $new_student{'key'} = $key;
    $existing = &get_patron($token, $student->{'barcode'});
  }

  foreach my $field (sort keys %{$client->{'fields'}}) {
    my $value = defined($student->{$field}) ? $student->{$field} : '';

    # Set default values 
    if ( $client->{'fields'}->{$field}->{$mode . '_default'} ) {
      $value = $client->{'fields'}->{$field}->{$mode . '_default'} unless $existing->{$field};
    }

    # Set fixed values for new records and overlays
    if ( $client->{'fields'}->{$field}->{$mode . '_value'} ) {
        $value = $client->{'fields'}->{$field}->{$mode . '_value'};
    }

    # Transform fields as needed
    $value = &transform_field($field, $value, $client, $student, $existing);

    # Execute validations for fields not in the incoming data
    if ( ! &in_array(\@district_schema, $field) ) {
      $value = &validate_field($field, $value, $client, $student);
    }

    # We've finish messing with the data, assign to $student
    $student->{$field} = $value;

    # If a field is null or undefined remove it from the hash, so we don't try to update the value in the existing record
    if ( ! defined($student->{$field}) || $student->{$field} eq 'null' ) {
      next;
    }

    switch($client->{'fields'}->{$field}->{'type'}) {
      case 'string' {
        if ( $mode eq 'new' || $client->{'fields'}->{$field}->{'overlay'} eq 'true' && $student->{$field} ) {
          $new_student{'fields'}{$field} = $student->{$field};
        }
      }
      case 'resource' {
        if ( $mode eq 'new' || $client->{'fields'}->{$field}->{'overlay'} eq 'true' && $student->{$field} ) {
          $new_student{'fields'}{$field}{'resource'} = "/policy/$resource{$field}";
          $new_student{'fields'}{$field}{'key'} = $student->{$field};
          }
      }
      case 'category' {
        if ( $mode eq 'new' || $client->{'fields'}->{$field}->{'overlay'} eq 'true' && $student->{$field} ) {
          $new_student{'fields'}{$field}{'resource'} = "/policy/$resource{$field}";
          $new_student{'fields'}{$field}{'key'} = $student->{$field};
        }
      }
      case 'address' {
        if ( $mode eq 'new' || $client->{'fields'}->{$field}->{'overlay'} eq 'true' && $student->{$field} ) {
          my %address = ();
          $address{'resource'} = '/user/patron/address1';
          $address{'fields'}{'code'}{'key'} = $resource{$field};
          $address{'fields'}{'code'}{'resource'} = '/policy/patronAddress1';
          $address{'fields'}{'data'} = $student->{$field};
          push @{$new_student{'fields'}{'address1'}}, ({%address});
        }
      }
    }
  }
  # Return a reference to the student data structure
  return \%new_student;
}

###############################################################################
# Calculate if age over thirteen from birthday.


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
  my $string = qq|"$student->{'barcode'}",|;
  $string   .= qq|"$student->{'firstName'}",|;
  $string   .= qq|"$student->{'middleName'}",|;
  $string   .= qq|"$student->{'lastName'}",|;
  $string   .= qq|"$student->{'street'}",|;
  $string   .= qq|"$student->{'city'}",|;
  $string   .= qq|"$student->{'state'}",|;
  $string   .= qq|"$student->{'zipCode'}",|;
  $string   .= qq|"$student->{'birthDate'}",|;
  $string   .= qq|"$student->{'email'}"|;

  return $string;
}

###############################################################################
# Checks if there is a function to validate a particular field. If there is
# one, it runs it, passing in the value, while will either be returned if it is
# valid or returned as null if it is not (in which case an error may be 
# returned by the calling code.

sub validate_field {
  my $field = shift;
  my $value = shift;
  my $client = shift;

  # Check for empty fields and return 'null' if found;
  return 'null' unless $value;

  my $rule = $client->{'fields'}->{$field}->{'validate'};

  if ( $rule && substr($rule, 0, 1) eq 'c' ) {

    my $sub = substr($rule, 2);
    if ( exists &{$sub} ) {
      my $subroutine = \&{$sub};

      # Run the function to check the value
      $value = $subroutine->($value);

    } else {
      &logger('error', "Custom validate subroutine $sub not found.");
    }

  } elsif ( $rule ) {

    if ( ! DataHandler::validate($value, $rule) ) {
        $value = '';
    }
  }

  return $value;
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
# Validates zipCode as ##### or #####-####.

sub validate_zipCode {
  my $value = shift;
  my $retval = '';

  if ( $value =~ /^\d{5}$/ || $value =~ /^\d{5}-\d{4}$/ ) {
    $retval = $value;
  }

  return $retval;
}

###############################################################################
# Transforms field

sub transform_field {
  my $field = shift;
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

  if ( $client->{'fields'}->{$field}->{'transform'} ) {
    my $sub = $client->{'fields'}->{$field}->{'transform'};

    if ( exists &{$sub} ) {
      my $subroutine = \&{$sub};

      # Run the function to check the value
      $value = $subroutine->($value, $client, $student, $existing);
    } else {
      # Report error
      &logger('error', "Custom transform subroutine $sub not found.");
    }
  }

  return $value;
}

###############################################################################
# Transform barcode

sub transform_barcode {
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

  if ( ref $existing eq ref {} && defined($existing->{'barcode'}) && $existing->{'barcode'} =~ /^\d{14}$/ ) {
    $student->{'alternateID'} = $value;
    $value = $existing->{'barcode'};
  } else {
    $value = $client->{'id'} . $value;
  }

  return $value;
}

###############################################################################
# Reformats the date of birth. Accepts dates in two formats:
# MM/DD/YYYY or M/D/YYYY HH:MM:SS AM|PM

sub transform_birthDate {
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

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
  } else {
    &logger('error', "Invalid date ($date) in transform_birthDate.");
  }

  return $retval;
}

###############################################################################
# Replaces email with incoming value only if existing email matches district
# pattern

sub transform_email {
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

  if ( ref $existing eq ref {} ) {
    my $match = 0;
    foreach my $i (0 .. $#{$yaml->[0]->{'clients'}}) {
      my $pattern = $yaml->[0]->{'clients'}->[$i]->{'email_pattern'};
      if ( $existing->{'email'} ) {
        my ($username, $domain) = split /\@/, $existing->{'email'};
        if ( $pattern eq $domain ) {
          $match = 1;
          last;
        }
      }
    }
    if ( $match ) {
      $value = $existing->{'email'};
    }
  }

  return $value
}
  
###############################################################################
# Creates default pin from birthDate

sub transform_pin {
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

  my $year = '1962';
  my $mon = '03';
  my $day = '07';
  if ( $student->{'birthDate'} =~ /^\d{4}-\d{2}-\d{2}$/ ) {
    ($year, $mon, $day) = split /\-/, $student->{'birthDate'};
  } else {
    &logger('error', "Invalid birthDate ($student->{'birthDate'}) in transform_pin.");
  }

  return "${mon}${day}${year}";
}

###############################################################################
# Selects profile based on age

sub transform_profile {
    my $value = shift;
    my $client = shift;
    my $student = shift;
    my $existing = shift;

    my $birthDate = '0000-00-00';
    if ( $student->{'birthDate'} =~ /^\d{4}-\d{2}-\d{2}$/ ) {
      $birthDate = $student->{'birthDate'};
      my ($year1, $month1, $day1) = split /-/, $birthDate;
      my ($year2, $month2, $day2) = Today();

      if (($day1 == 29) && ($month1 == 2) && !leap_year($year2)) { $day1--; };

      if ( (($year2 - $year1) >  17) || ( (($year2 - $year1) == 17) 
        && (Delta_Days($year2,$month1,$day1, $year2,$month2,$day2) >= 0) ) ) {

        $value = $yaml->[0]->{'adult_profile'};
      }
    } else {
      &logger('error', "Invalid birthDate ($student->{'birthDate'}) in transform_profile.");
    }

    return $value;
}

###############################################################################
# Use the AddressFormat.pm function to validate and reformat to USPS standards

sub transform_street {
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

  return AddressFormat::format_street($value);
}

###############################################################################
# Use the AddressFormat.pm function to validate and reformat to USPS standard

sub transform_city {
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

  return AddressFormat::format_city($value);
}

###############################################################################
# Use the AddressFormatpm function to validate and reformat to USPS standard

sub transform_state {
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

  return AddressFormat::format_state($value);
}

###############################################################################
# Combine the city and state into one field

sub transform_cityState {
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

  $value = $student->{'city'} . ', ' . $student->{'state'};

  return $value;
}

###############################################################################
# Sets the school district in category03 based on the configuration

sub transform_category03 {
  my $value = shift;
  my $client = shift;
  my $student = shift;
  my $existing = shift;

  return $client->{'id'} . '-' . $client->{'name'};
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

  my $barcode = $student->{'barcode'};

  # Default is to assume that the data has changed
  my $retval = 1;

  # Create an MD5 digest from the incoming student data
  my $checksum = &digest($student);

  my $sql = qq|SELECT chksum FROM checksums WHERE student_id = '$barcode'|;
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
      $sql = qq|UPDATE checksums SET chksum = '$checksum' WHERE student_id = '$barcode'|;
      $sth = $dbh->prepare($sql);
      $sth->execute() or &error_handler("Could not update checksums: $dbh->errstr()");

      &logger('debug', "Student data changed, updating checksum database");
    }

  } else {

    # We did not find a checksum record for this student, so we should add one
    $sql = qq|INSERT INTO checksums (student_id, chksum, date_added) VALUES ('$barcode', '$checksum', CURDATE())|;
    $sth = $dbh->prepare($sql);
    $sth->execute() or &error_handler("Could not add record to checksums: $dbh->errstr()");

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
# Get existing record values for all supported fields

sub get_patron {
  my $barcode = shift;

  my %patron = ();
  my @fields = ( 
    'alternateID',
    'barcode',
    'firstName',
    'middleName',
    'lastName',
    'birthDate',
    'address1',
    'pin',
    'profile',
    'library',
    'category01',
    'category02',
    'category03',
    'category07',
    'category08',
    'category09',
    'category10',
    'category11',
    'category12'
    );
  my %address = (
    'STREET' => 'street',
    'CITY/STATE' => 'cityState',
    'ZIP' => 'zipCode',
    'PHONE' => 'telephone',
    'EMAIL' => 'email'
    );

  my $field_list = join(',', @fields);
  my %options = (ct => 20, includeFields => $field_list);
  my $r = ILSWS::patron_search($token, 'ID', "$barcode", \%options);

  if ( $r && $r->{'totalResults'} >= 1 ) {
    # Get the strings
    foreach my $field ('alternateID','barcode','firstName','lastName','middleName','birthDate','pin') {
      $patron{$field} = $r->{'result'}[0]{'fields'}{$field};
    }
    # Get the resource items
    foreach my $field ('library','profile') {
      $patron{$field} = $r->{'result'}[0]{'fields'}{$field}{'key'};
    }
    # Get the category items
    foreach my $i ('01','02','03','04','05','06','07','08','09','10','11','12') {
      $patron{"category$i"} = $r->{'result'}[0]{'fields'}{"category$i"}{'key'};
    }
    for (my $i = 0; $i <= $#{$r->{'result'}[0]{'fields'}{'address1'}}; $i++) {
      my $field = $address{$r->{'result'}[0]{'fields'}{'address1'}[$i]{'fields'}{'code'}{'key'}};
      $patron{$field} = $r->{'result'}[0]{'fields'}{'address1'}[$i]{'fields'}{'data'};
    }
  }

  return \%patron;
}

###############################################################################

###############################################################################
# EOF
