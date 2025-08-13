#!/usr/bin/perl
#
# ReLibConnectEd Ingestor
#
# This script is run by relibconnected.pl when an upload file is detected. It
# takes two required parameters: the absolute path to its configuration file
# (config.yaml) and the absolute path to the data file to be ingested.

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
use Data::Dumper qw(Dumper); # Keep Dumper for debugging output, avoid in production logs for sensitive data
use Unicode::Normalize;
use Email::Valid;
use Try::Tiny;
use Digest::MD5 qw(md5_hex);
use DBI;
use DBD::mysql;
use JSON; # Add JSON module, as it's used in create_student/update_student

# Load local modules
use AddressFormat; # Assumed to be in @INC or same directory
use DataHandler;   # Assumed to be in @INC or same directory

# --- Global Variables (carefully considered 'our' usage) ---
# $yaml is truly global as it's loaded in a BEGIN block and needed throughout.
our $yaml;

# Constants for exit status
use constant EXIT_SUCCESS => 0;
use constant EXIT_FAILURE => 1;

# Valid fields in uploaded CSV files - declared as 'our' if truly shared
# with other modules, otherwise 'my'. Given their direct use, 'our' might be fine.
our @district_schema = qw(barcode firstName middleName lastName street city state zipCode birthDate email);
our @pps_schema      = qw(firstName middleName lastName barcode street city state zipCode birthDate email);

# Counters for statistics - these are modified globally, so 'our' is appropriate
# but they should ideally be passed around or encapsulated in an object.
our $update_cnt    = 0;
our $create_cnt    = 0;
our $ambiguous_cnt = 0;
our $checksum_cnt  = 0;
our $alt_id_cnt    = 0;
our $email_cnt     = 0;
our $id_cnt        = 0;
our $dob_street_cnt = 0;
our $lineno        = 0; # Current line number in CSV, used for logging

# Global logger instance
our $log;
our $csv_logger; # For the CSV output log

# --- BEGIN Block for Configuration Loading (executed at compile time) ---
BEGIN {
    # Validate command-line arguments for config file path
    # $ARGV[0] should be the path to config.yaml
    unless (defined $ARGV[0] && -f $ARGV[0] && -r $ARGV[0]) {
        die "ERROR: Configuration file not provided or not readable as the first argument.\n";
    }

    # Attempt to read the YAML configuration file
    my $config_file_path = $ARGV[0];
    eval {
        $yaml = YAML::Tiny->read($config_file_path);
    };
    if ($@) {
        die "ERROR: Failed to read YAML configuration file '$config_file_path': $@\n";
    }

    # Validate that $yaml is defined and contains expected structure
    # unless (defined $yaml && ref $yaml eq 'ARRAY' && @$yaml && ref $yaml->[0] eq 'HASH') {
    unless (defined $yaml && ref $yaml->[0] eq 'HASH') {
        die "ERROR: Invalid YAML configuration structure in '$config_file_path'.\n";
    }

    # Set ILSWS_BASE_PATH from config, required before ILSWS module is used
    if (defined $yaml->[0]->{'base_path'}) {
        $ENV{'ILSWS_BASE_PATH'} = $yaml->[0]->{'base_path'};
    } else {
        die "ERROR: 'base_path' not defined in YAML configuration file '$config_file_path'.\n";
    }
}

# Do this after the BEGIN so that ILSWS gets the base path from the environment
# Assumes ILSWS.pm is in a path specified by $ENV{'ILSWS_BASE_PATH'} or @INC
use ILSWS; # Removed explicit path as it's handled by $ENV{'ILSWS_BASE_PATH'}

# --- Main Script Logic ---
my $exit_status = EXIT_FAILURE; # Default to failure

# Read configuration file data (already loaded in BEGIN block)
my $base_path = $yaml->[0]->{'base_path'};

# Get the logging configuration from the log.conf file
Log::Log4perl->init("$base_path/log.conf");
$log = get_logger('log');
$csv_logger = get_logger('csv'); # Initialize CSV logger

# Set the log level based on the log_level in config.yaml
my $log_level_str = lc($yaml->[0]->{'log_level'} // 'debug'); # Default to 'debug' if not defined
if ($log_level_str eq 'info') {
    $log->level($INFO);
} elsif ($log_level_str eq 'warn') {
    $log->level($WARN);
} elsif ($log_level_str eq 'error') {
    $log->level($ERROR);
} elsif ($log_level_str eq 'debug') {
    $log->level($DEBUG);
} elsif ($log_level_str eq 'fatal') {
    $log->level($FATAL);
} else {
    $log->level($DEBUG); # Fallback for unknown levels
}

# Validate email from address before starting.
my $from_email = $yaml->[0]->{'smtp'}->{'from'} // '';
if (validate_email($from_email) eq 'null') {
    error_handler("Invalid 'from' address in configuration: '$from_email'");
}

# CSV file where we'll log updates and creates. Must match CSVFILE defined in log.conf!
my $csv_file = "$base_path/log/ingestor.csv";

# Mail log file which will be sent as body of report message. Must match MAILFILE defined in log.conf!
my $mail_log = "$base_path/log/mail.log";

# Get the path to the student data file passed to script by relibconnected.pl
my $data_file = $ARGV[1]; # Second argument

# Check that the data file is readable
unless (defined $data_file && -f $data_file && -r $data_file) {
    error_handler("Data file not provided, does not exist, or is not readable: '$data_file'");
}
my $file_size = -s $data_file;

# Log start of ingest
logger('info', "Ingestor run on '$data_file' ($file_size bytes) started");

# Derive the ID and namespace of the school district from the path of the
# data file
my $dirname = dirname($data_file);
my @parts = split /\//, $dirname;
my $district = $parts[$#parts - 1]; # e.g., "namespaceID"
my $id = substr($district, -2);
my $namespace = substr($district, 0, -2);

# See if we have a configuration from the YAML file that matches the district
# derived from the file path. If so, put the configuration in $client.
my $client_config = {}; # Use a hash reference, initialized to empty
my $clients_list = $yaml->[0]->{'clients'} // []; # Ensure it's an array ref
foreach my $i (0 .. $#{$clients_list}) {
    if (defined $clients_list->[$i]->{'namespace'} && defined $clients_list->[$i]->{'id'}) {
        if ($clients_list->[$i]->{'namespace'} eq $namespace && $clients_list->[$i]->{'id'} eq $id) {
            $client_config = $clients_list->[$i];
            last; # Found a match, no need to continue loop
        }
    }
}

# Die with an error, if we didn't find a matching configuration
unless (defined $client_config->{'id'}) {
    error_handler("Could not find configuration for district '$district' derived from data file path.");
}

# If we did find a configuration, let the customer know
logger('info', "Found configuration for district '$district' (name: $client_config->{'name'}).");

# Open the CSV data file supplied by calling script, relibconnected.pl
my $data_fh;
open($data_fh, '<', $data_file)
    or error_handler("Could not open data file: '$data_file': $!");

# Create CSV parser
my $parser = Parse::CSV->new(handle => $data_fh, sep_char => ',', names => 1);

# Change all field names to lower case and map to Symphony names.
# The @fields array is now lexical to this scope, or passed explicitly if needed.
# This hash converts incoming field names to those expected by Symphony
# and used in the config.yaml file.
my %symphony_names = (
    student_id  => 'barcode',
    first_name  => 'firstName',
    middle_name => 'middleName',
    last_name   => 'lastName',
    address     => 'street',
    city        => 'city',
    state       => 'state',
    zipcode     => 'zipCode',
    dob         => 'birthDate',
    email       => 'email',
);

my @parsed_fields = $parser->names;
foreach my $i (0 .. $#parsed_fields) {
    my $lc_field = lc($parsed_fields[$i]);
    $parsed_fields[$i] = $symphony_names{$lc_field} // $parsed_fields[$i]; # Use original if no mapping found
}
$parser->names(@parsed_fields);

# Check that the field order matches the expected schema
my $expected_schema_ref;
if ($client_config->{'schema'} eq 'district') {
    $expected_schema_ref = \@district_schema;
} elsif ($client_config->{'schema'} eq 'pps') {
    $expected_schema_ref = \@pps_schema;
} else {
    error_handler("Unknown schema type '$client_config->{'schema'}' specified in configuration.");
}

unless (check_schema(\@parsed_fields, $expected_schema_ref)) {
    error_handler("Fields in '$data_file' don't match expected schema for client '$district'.");
}

# Start the CSV file output with the column headers
$csv_logger->info(qq|"action","match","| . join('","', @district_schema) . qq|"|);

# Connect to ILSWS.
my $ilsws_token = ILSWS::ILSWS_connect();
if ($ilsws_token) {
    logger('info', "Login to ILSWS '$yaml->[0]->{'ilsws'}->{'webapp'}' successful.");
} else {
    error_handler("Login to ILSWS failed: $ILSWS::error"); # Assumes ILSWS module sets $ILSWS::error
}

# Connect to checksums database
my $dbh = connect_database();

# Loop through lines of data and check for valid values. Ingest valid lines.
while (my $student_record = $parser->fetch) {
    $lineno++; # Increment global line number for logging

    my $errors_in_record = 0;
    foreach my $field_name (keys %{$student_record}) {
        # Validate data in each field as configured in config.yaml
        my $validated_value = validate_field($field_name, $student_record->{$field_name}, $client_config);

        if (!defined $validated_value || $validated_value eq '') {
            # Try to truncate and then validate again
            $validated_value = truncate_field($field_name, $student_record->{$field_name}, $client_config);
            $validated_value = validate_field($field_name, $validated_value, $client_config);
        }

        # Log any errors for non-email fields, email can be 'null'
        if (!defined $validated_value || $validated_value eq '') {
            # Check if it's an email field and if null is allowed
            if ($field_name eq 'email' && $client_config->{'fields'}->{'email'}->{'allow_null'}) {
                $student_record->{$field_name} = 'null';
            } else {
                logger('error', "Invalid data in line $lineno, field '$field_name': '" . ($student_record->{$field_name} // '') . "'");
                $errors_in_record++;
            }
        } else {
            $student_record->{$field_name} = $validated_value;
        }
    }

    if ($errors_in_record > 0) {
        # We got errors when validating this student's data, so log and skip
        logger('error', "Skipping " . ($student_record->{'lastName'} // 'N/A') . ", " . ($student_record->{'firstName'} // 'N/A') . " (" . ($student_record->{'barcode'} // 'N/A') . " at line $lineno) due to data error(s).");
    } else {
        # Check the checksum database for changes to the data or for new data
        # and process the student record only if necessary
        if (check_for_changes($student_record, $client_config, $dbh)) {
            process_student($ilsws_token, $client_config, $student_record);
        } else {
            $checksum_cnt++;
        }
    }
}

# Disconnect from the checksums database
$dbh->disconnect;

# Close data file
close($data_fh) or error_handler("Could not close data file: '$data_file': $!");

# Tell 'em we're finished
logger('info', "Ingestor run on '$data_file' finished.");
logger('info', "Statistics: $update_cnt updates, $create_cnt creates, $ambiguous_cnt ambiguous.");
logger('info', "Matches: $checksum_cnt Checksum, $alt_id_cnt Alt ID, $id_cnt ID, $email_cnt Email, $dob_street_cnt DOB and Street.");

# Validate admin contact email addresses
my @admin_addresses = split /,\s*/, $yaml->[0]->{'admin_contact'} // '';
my @report_addresses = ();

if ($client_config->{'email_reports'} eq 'true') {
    my @client_contacts = split /,\s*/, $client_config->{'contact'} // '';
    push @admin_addresses, @client_contacts;
}

foreach my $addr (@admin_addresses) {
    if (validate_email($addr) ne 'null') {
        push @report_addresses, $addr;
    } else {
        logger('error', "Invalid email address in configuration (skipped): '$addr'");
    }
}

unless (@report_addresses) {
    error_handler("No valid email addresses found for sending reports. Check 'admin_contact' and client 'contact' in config.");
}

# Prepare email to the admin contact with the mail.log and ingester.csv files as attachments
my $mailer = Email::Mailer->new(
    to          => join(',', @report_addresses),
    from        => $from_email,
    subject     => "RELIBCONNECTED Ingest Report $client_config->{'name'} ($client_config->{'namespace'}$client_config->{'id'})",
    text        => "Log and CSV output files from RELIBCONNECT ingest.",
    attachments => [
        { ctype => 'text/plain', source => $mail_log },
        { ctype => 'text/csv',   source => $csv_file },
    ],
);

try {
    # Mail the logs to the admin contact(s)
    $mailer->send;
    logger('info', "Ingest report email sent successfully to: " . join(', ', @report_addresses));
} catch {
    error_handler("Could not email logs: $_"); # $_ contains the exception message
};

# Delete the mail log and the CSV file
unlink $mail_log or logger('error', "Could not delete mail log file '$mail_log': $!");
unlink $csv_file or logger('error', "Could not delete CSV log file '$csv_file': $!");

# Delete the ingest data file
unlink $data_file or logger('error', "Could not delete data file '$data_file': $!");

$exit_status = EXIT_SUCCESS;
exit($exit_status);

###############################################################################
# Subroutines
###############################################################################

# --- File Security Validation ---
# This function checks if a file exists, is readable, is owned by the effective UID,
# and has secure permissions. It issues warnings for insecure permissions but dies
# for critical access/ownership issues.
sub _validate_secure_file_access {
    my ($file_path, $file_purpose) = @_;

    unless (defined $file_path && -f $file_path) {
        error_handler("Required file '$file_purpose' does not exist or is not a regular file: '$file_path'");
    }
    unless (-r $file_path) {
        error_handler("Required file '$file_purpose' is not readable by the current user: '$file_path'");
    }

    my $st = stat($file_path) or error_handler("Could not stat file '$file_path' for '$file_purpose': $!");

    # Check ownership: The file must be owned by the effective user ID running the script.
    unless ($st->uid == $<) {
        # This might be a warning rather than fatal if the script is designed to run
        # with different ownership, but for sensitive config/data, it's safer to die.
        error_handler("File '$file_path' for '$file_purpose' is not owned by the current effective user (UID $<).");
    }

    # Check permissions: Permissions should be restrictive (0600 or 0400) for security.
    my $permissions = $st->mode & 0777;
    unless ($permissions == 0600 || $permissions == 0400) {
        logger('warn', "File '$file_path' for '$file_purpose' has insecure permissions (0" . sprintf("%o", $permissions) . "). Recommended: 0600 or 0400.");
    }
    return 1;
}

# Process a student. This is the core logic where we decide if we are going to
# update (overlay) a record, create a new record, or log the data only due to
# multiple ambiguous matches.
sub process_student {
    my ($token, $client, $student) = @_;

    my $patron_id = $client->{'id'} . $student->{'barcode'};

    # 1. Check for existing patron with same student ID in the ALT_ID field
    my %options = ( ct => 1, includeFields => 'barcode' );
    my $existing_alt_id_result;
    eval {
        $existing_alt_id_result = ILSWS::patron_alt_id_search($token, $patron_id, \%options);
    };
    if ($@ || ($ILSWS::code && $ILSWS::code != 200)) {
        logger('error', "ILSWS::patron_alt_id_search failed for '$patron_id': " . ($ILSWS::error // $@));
    } elsif (defined $existing_alt_id_result && $existing_alt_id_result->{'totalResults'} == 1 && $existing_alt_id_result->{'result'}->[0]->{'key'}) {
        $alt_id_cnt++;
        update_student($token, $client, $student, $existing_alt_id_result->{'result'}->[0]->{'key'}, 'Alt ID');
        $update_cnt++;
        return 1;
    }

    # 2. Search for the student via email address (if provided)
    if ($student->{'email'} && $student->{'email'} ne 'null') {
        %options = ( ct => 2, includeFields => 'barcode' ); # Limit to 2 to detect ambiguity
        my $existing_email_result;
        eval {
            $existing_email_result = ILSWS::patron_search($token, 'EMAIL', $student->{'email'}, \%options);
        };
        if ($@ || ($ILSWS::code && $ILSWS::code != 200)) {
            logger('error', "ILSWS::patron_search (EMAIL) failed for '$student->{'email'}': " . ($ILSWS::error // $@));
        } elsif (defined $existing_email_result && $existing_email_result->{'totalResults'} == 1 && $existing_email_result->{'result'}->[0]->{'key'}) {
            $email_cnt++;
            update_student($token, $client, $student, $existing_email_result->{'result'}->[0]->{'key'}, 'Email');
            $update_cnt++;
            return 1;
        }
    }

    # 3. Check for existing patron with same student ID in the ID field (barcode)
    %options = ( ct => 1, includeFields => 'barcode' );
    my $existing_barcode_result;
    eval {
        $existing_barcode_result = ILSWS::patron_barcode_search($token, $patron_id, \%options);
    };
    if ($@ || ($ILSWS::code && $ILSWS::code != 200)) {
        logger('error', "ILSWS::patron_barcode_search failed for '$patron_id': " . ($ILSWS::error // $@));
    } elsif (defined $existing_barcode_result && $existing_barcode_result->{'totalResults'} == 1 && $existing_barcode_result->{'result'}->[0]->{'key'}) {
        $id_cnt++;
        update_student($token, $client, $student, $existing_barcode_result->{'result'}->[0]->{'key'}, 'ID');
        $update_cnt++;
        return 1;
    }

    # 4. Search by DOB and street
    my $dob_street_matches = search_by_dob_and_street($token, $client, $student);

    if (scalar @{$dob_street_matches} == 1) {
        # Looks like this student may have moved
        if (defined $dob_street_matches->[0]->{'key'}) {
            $dob_street_cnt++;
            update_student($token, $client, $student, $dob_street_matches->[0]->{'key'}, 'DOB and Street');
            $update_cnt++;
        }
    } elsif (scalar @{$dob_street_matches} > 1) {
        # We got multiple matches, so reject the search results as ambiguous
        # and report the new student data in logs.
        logger('debug', qq|"AMBIGUOUS:","DOB and Street",| . print_line($student));
        $csv_logger->info(qq|"Ambiguous","DOB and Street",| . print_line($student));
        $ambiguous_cnt++;
    } else {
        # All efforts to match this student failed, so create new record for them
        create_student($token, $client, $student);
        $create_cnt++;
    }

    return 1;
}

# Search ILSWS on DOB and street to match existing student
sub search_by_dob_and_street {
    my ($token, $client, $student) = @_;

    my @results = ();

    my ($year, $mon, $day) = split /\-/, transform_birthDate($student->{'birthDate'}, $client, $student);
    my %options = (
        ct            => 20,
        includeFields => 'barcode,firstName,middleName,lastName'
    );

    my $bydob_result;
    eval {
        $bydob_result = ILSWS::patron_search($token, 'BIRTHDATE', "${year}${mon}${day}", \%options);
    };
    if ($@ || ($ILSWS::code && $ILSWS::code != 200)) {
        logger('error', "ILSWS::patron_search (BIRTHDATE) failed: " . ($ILSWS::error // $@));
    }

    if (defined $bydob_result && defined($bydob_result->{'totalResults'}) && $bydob_result->{'totalResults'} >= 1) {
        # If we found a person or persons with student's DOB, then we continue
        # by searching via street.

        # Remove punctuation from street before searching
        my $street_val = $student->{'street'} // '';
        $street_val =~ s/#//g;
        my $bystreet_result;
        eval {
            $bystreet_result = ILSWS::patron_search($token, 'STREET', $street_val, \%options);
        };
        if ($@ || ($ILSWS::code && $ILSWS::code != 200)) {
            logger('error', "ILSWS::patron_search (STREET) failed: " . ($ILSWS::error // $@));
        }

        if (defined $bystreet_result && defined($bystreet_result->{'totalResults'}) && $bystreet_result->{'totalResults'} >= 1) {
            # Compare the two result sets to see if we can find the same student
            # in both the DOB and street result sets
            @results = compare_results($bydob_result->{'result'}, $bystreet_result->{'result'});

            if (scalar @results >= 1) { # If there are any results (even one for update, or multiple for ambiguity)
                # Now report the possible matches
                foreach my $match_rec (@results) {
                    # Add each ambiguous record to the CSV log with the ID and name
                    # information. Put the student ID in the the ID field along with the
                    # matching record ID, so the CSV can be storted appropriately. Add
                    # name and streets from matching records.
                    my @message_parts = ();
                    push(@message_parts, qq|"Ambiguous","DOB and Street"|);
                    push(@message_parts, qq|"$student->{'barcode'}, $match_rec->{'key'}"|);
                    if (defined $match_rec->{'fields'}->{'firstName'}) {
                        push(@message_parts, qq|"$match_rec->{'fields'}->{'firstName'}"|);
                    }
                    if (defined $match_rec->{'fields'}->{'middleName'}) {
                        push(@message_parts, qq|"$match_rec->{'fields'}->{'middleName'}"|);
                    }
                    if (defined $match_rec->{'fields'}->{'lastName'}) {
                        push(@message_parts, qq|"$match_rec->{'fields'}->{'lastName'}"|);
                    }
                    $csv_logger->info(join(',', @message_parts));
                    logger('debug', "Ambiguous match details: " . Dumper($match_rec));
                }
            }
        }
    }

    # Return a reference to the @results array
    return \@results;
}

# Compare result sets from ILSWS searches and return array of record hashes
# where the records share the same user key
sub compare_results {
    my ($set1_ref, $set2_ref) = @_;

    my @common_results = ();

    # Ensure inputs are array references
    unless (ref $set1_ref eq 'ARRAY' && ref $set2_ref eq 'ARRAY') {
        logger('error', "compare_results received non-array references.");
        return ();
    }

    my %keys_in_set1;
    foreach my $rec (@$set1_ref) {
        if (defined $rec && defined $rec->{'key'}) {
            $keys_in_set1{$rec->{'key'}} = $rec;
        }
    }

    foreach my $rec (@$set2_ref) {
        if (defined $rec && defined $rec->{'key'} && exists $keys_in_set1{$rec->{'key'}}) {
            # Found a common record, add it to results
            push @common_results, {
                key    => $rec->{'key'},
                fields => {
                    barcode    => $rec->{'fields'}->{'barcode'} // '',
                    firstName  => $rec->{'fields'}->{'firstName'} // '',
                    middleName => $rec->{'fields'}->{'middleName'} // '',
                    lastName   => $rec->{'fields'}->{'lastName'} // '',
                },
            };
        }
    }

    return @common_results;
}

# Create new student record
sub create_student {
    my ($token, $client, $student) = @_;

    my $json_encoder = JSON->new->allow_nonref;

    # Put student data into the form expected by ILSWS.
    my $new_student_data = create_data_structure($token, $student, $client);

    # Convert the data structure into JSON
    my $student_json = $json_encoder->pretty->encode($new_student_data);
    logger('debug', "JSON for patron create: " . $student_json);

    # Remove diacritics
    $student_json = NFKD($student_json);
    $student_json =~ s/\p{NonspacingMark}//g;

    # Set the max retries
    my $max_retries = $yaml->[0]->{'ilsws'}->{'max_retries'} // 3; # Default to 3

    my $create_success = 0;
    my $retries = 1;
    while (!$create_success && $retries <= $max_retries) {
        my $res;
        eval {
            # Send the patron create JSON to ILSWS
            $res = ILSWS::patron_create($token, $student_json);
        };

        if ($@) {
            logger('error', "Exception during ILSWS::patron_create for " . ($student->{'barcode'} // 'N/A') . " (line $lineno) on attempt $retries: $@");
        } elsif (!defined $res || ($ILSWS::code && $ILSWS::code != 200)) {
            logger('error', "Failed to create " . ($student->{'barcode'} // 'N/A') . " (line $lineno) on attempt $retries: " . ($ILSWS::code // 'N/A') . ": " . ($ILSWS::error // 'No specific error message.') . " Data: " . print_line($student));
        } else {
            $create_success = 1; # Mark as success
        }

        unless ($create_success) {
            sleep($retries * 2); # Exponential back-off
            $retries++;
        }
    }

    if ($create_success) {
        # We created a patron. Log the event.
        $csv_logger->info(qq|"Create",""| . print_line($student));
        logger('debug', "CREATE: " . ($student->{'lastName'} // 'N/A') . ", " . ($student->{'firstName'} // 'N/A') . " (" . ($student->{'barcode'} // 'N/A') . ") created.");
    } else {
        logger('error', "Persistent failure to create patron " . ($student->{'barcode'} // 'N/A') . " after $max_retries attempts.");
    }
}

# Check if value in array
sub in_array {
    my ($arr_ref, $search_for) = @_;
    unless (ref $arr_ref eq 'ARRAY') {
        logger('error', "in_array expects an array reference.");
        return 0;
    }
    foreach my $value (@$arr_ref) {
        return 1 if $value eq $search_for;
    }
    return 0;
}

# Update existing student
sub update_student {
    my ($token, $client, $student, $key, $match_type) = @_;

    my $json_encoder = JSON->new->allow_nonref;

    # Put student data into the form expected by ILSWS.
    my $updated_student_data = create_data_structure($token, $student, $client, $key);

    # Convert the data structure into JSON
    my $student_json = $json_encoder->pretty->encode($updated_student_data);
    logger('debug', "JSON for patron update (key $key): " . $student_json);

    # Remove diacritics
    $student_json = NFKD($student_json);
    $student_json =~ s/\p{NonspacingMark}//g;

    # Set the max retries
    my $max_retries = $yaml->[0]->{'ilsws'}->{'max_retries'} // 3; # Default to 3

    my $update_success = 0;
    my $retries = 1;
    while (!$update_success && $retries <= $max_retries) {
        my $res;
        eval {
            # Send the patron update JSON to ILSWS
            $res = ILSWS::patron_update($token, $student_json, $key);
        };

        if ($@) {
            logger('error', "Exception during ILSWS::patron_update for " . ($student->{'barcode'} // 'N/A') . " (line $lineno, key $key) on attempt $retries: $@");
        } elsif (!defined $res || ($ILSWS::code && $ILSWS::code != 200)) {
            logger('error', "Failed to update " . ($student->{'barcode'} // 'N/A') . " (line $lineno, key $key) on attempt $retries: " . ($ILSWS::code // 'N/A') . ": " . ($ILSWS::error // 'No specific error message.') . " Data: " . print_line($student));
        } else {
            $update_success = 1; # Mark as success
        }

        unless ($update_success) {
            sleep($retries * 2); # Exponential back-off
            $retries++;
        }
    }

    if ($update_success) {
        # We got a result! Yay!
        $csv_logger->info(qq|"Update","$match_type",| . print_line($student));
        logger('debug', "OVERLAY: " . ($student->{'lastName'} // 'N/A') . ", " . ($student->{'firstName'} // 'N/A') . " (" . ($student->{'barcode'} // 'N/A') . ") updated with key $key.");
    } else {
        logger('error', "Persistent failure to update patron " . ($student->{'barcode'} // 'N/A') . " (key $key) after $max_retries attempts.");
    }
}

# Create the datastructure for an ILSWS query to create or update a patron
# record in Symphony
sub create_data_structure {
    my ($token, $student_data, $client_config, $key_val) = @_;

    # Hash to associate resources with field names. Only needed for resources,
    # address elements, and categories, not strings
    my %resource_map = (
        'category01' => 'patronCategory01', 'category02' => 'patronCategory02',
        'category03' => 'patronCategory03', 'category04' => 'patronCategory04',
        'category05' => 'patronCategory05', 'category06' => 'patronCategory06',
        'category07' => 'patronCategory07', 'category08' => 'patronCategory08',
        'category09' => 'patronCategory09', 'category10' => 'patronCategory10',
        'category11' => 'patronCategory11', 'category12' => 'patronCategory12',
        'library'    => 'library',
        'profile'    => 'userProfile',
        'street'     => 'STREET',
        'cityState'  => 'CITY/STATE',
        'zipCode'    => 'ZIP',
        'email'      => 'EMAIL',
        'birthDate'  => 'birthDate' # Used for patron_create/update, not a policy resource
    );

    # Determine the mode: 'overlay' if $key_val is provided and looks like a numeric key
    my $mode = (defined $key_val && $key_val =~ /^\d+$/) ? 'overlay' : 'new';

    my %new_patron_struct = ();
    $new_patron_struct{'resource'} = '/user/patron';
    $new_patron_struct{'fields'}{'address1'} = []; # Initialize as array ref for addresses

    my $existing_patron_fields = {};
    if ($mode eq 'overlay') {
        $new_patron_struct{'key'} = $key_val;
        # Retrieve existing patron data to apply overlay logic
        $existing_patron_fields = get_patron($token, $client_config->{'id'} . $student_data->{'barcode'});
    }

    # Iterate through fields defined in client_config->{'fields'}
    # Use a copy of the student data for transformations to avoid modifying original while iterating
    my %current_student_data = %{$student_data};

    foreach my $field_name (sort keys %{$client_config->{'fields'} // {}}) {

        my $value = defined($current_student_data{$field_name}) ? $current_student_data{$field_name} : '';

        # Set default values for overlay mode if existing value is empty
        if ($mode eq 'overlay' && defined($client_config->{'fields'}->{$field_name}->{$mode . '_default'}) && !length($existing_patron_fields->{$field_name} // '')) {
            $value = $client_config->{'fields'}->{$field_name}->{$mode . '_default'};
        }

        # Set fixed values for new records and overlays (overrides defaults and incoming data)
        if (defined($client_config->{'fields'}->{$field_name}->{$mode . '_value'})) {
            $value = $client_config->{'fields'}->{$field_name}->{$mode . '_value'};
        }

        # Transform fields as needed (e.g., barcode prefix, date format, address formatting)
        $value = transform_field($field_name, $value, $client_config, \%current_student_data, $existing_patron_fields);

        # Execute validations for fields not in the incoming data.
        # (Those were validated earlier during CSV processing).
        if (!in_array(\@district_schema, $field_name)) {
            $value = validate_field($field_name, $value, $client_config);
        }

        # If a field is 'null' or undefined after processing, skip it for update/create
        # This prevents sending empty values that might overwrite existing valid data with nothing
        if (!defined($value) || $value eq '' || $value eq 'null') {
            next;
        }

        # Assign the final processed value back to a temporary student hash for structure building
        $current_student_data{$field_name} = $value;

        # Build the JSON structure based on field type
        my $field_type = $client_config->{'fields'}->{$field_name}->{'type'};
        my $overlay_setting = $client_config->{'fields'}->{$field_name}->{'overlay'} // 'true'; # Default to overlay if not specified

        if ($mode eq 'new' || ($overlay_setting eq 'true' && defined $current_student_data{$field_name})) {
            if ($field_type eq 'string' || $field_type eq 'date') {
                $new_patron_struct{'fields'}{$field_name} = $current_student_data{$field_name};
            } elsif ($field_type eq 'address') {
                my %address_entry = (
                    resource => '/user/patron/address1',
                    fields   => {
                        code => {
                            resource => '/policy/patronAddress1',
                            key      => $resource_map{$field_name} // die "Unknown address resource map for $field_name",
                        },
                        data => $current_student_data{$field_name},
                    },
                );
                push @{$new_patron_struct{'fields'}{'address1'}}, \%address_entry;
            } elsif ($field_type eq 'resource' || $field_type eq 'category') {
                $new_patron_struct{'fields'}{$field_name}{'resource'} = "/policy/" . ($resource_map{$field_name} // $field_name);
                $new_patron_struct{'fields'}{$field_name}{'key'} = $current_student_data{$field_name};
            }
        }
    }
    # Return a reference to the newly constructed patron data structure
    return \%new_patron_struct;
}

# Log errors and exit
sub error_handler {
    my $message = shift;

    # Add caller info only if not already done by logger sub
    my ($package, $filename, $line) = caller;
    $log->error("$package:${line}: $message");

    exit(EXIT_FAILURE);
}

# Sends log messages to multiple logs as needed. Generally, we log to
# the permanent log and to the temporary log which will be mailed at the
# end of the ingest. Separate commands are used to send data to the CSV file.
sub logger {
    my ($level, $message) = @_;
    $level = lc($level);

    # Log more information to the permanent log for errors/fatal
    if ($level eq 'warn' || $level eq 'error' || $level eq 'fatal') {
        # Add the calling package and line number to errors
        my ($package, $filename, $line) = caller(1); # Get caller's context
        $log->$level("$package:${line}: $message");
    } else {
        $log->$level($message);
    }
}

# Checks if the field headings in the incoming student data file match the
# expected names in $valid_fields_ref
sub check_schema {
    my ($fields_ref, $valid_fields_ref) = @_;

    my $errors = 0;

    unless (ref $fields_ref eq 'ARRAY' && ref $valid_fields_ref eq 'ARRAY') {
        logger('error', "check_schema received non-array references.");
        return 0;
    }

    if (scalar @$fields_ref != scalar @$valid_fields_ref) {
        logger('error', "Schema mismatch: Incoming field count (" . scalar @$fields_ref . ") does not match expected schema count (" . scalar @$valid_fields_ref . ").");
        $errors++;
    }

    foreach my $i (0 .. $#{$fields_ref}) {
        # Ensure we don't go out of bounds if field counts differ
        if ($i > $#{$valid_fields_ref}) {
            logger('error', "Schema mismatch: Extra field in incoming data at position $i: '" . ($fields_ref->[$i] // '') . "'");
            $errors++;
            next;
        }
        if ($fields_ref->[$i] ne $valid_fields_ref->[$i]) {
            logger('error', "Schema mismatch: Invalid field in position $i. Expected '" . ($valid_fields_ref->[$i] // '') . "', got '" . ($fields_ref->[$i] // '') . "'.");
            $errors++;
        }
    }

    return $errors == 0 ? 1 : 0;
}

# Produces a line of student data in comma-delimited form, quoted for CSV.
sub print_line {
    my $student_hash_ref = shift;
    no warnings 'uninitialized'; # Temporarily disable for interpolation, re-enable after.

    unless (ref $student_hash_ref eq 'HASH') {
        logger('error', "print_line received non-hash reference.");
        return '';
    }

    # Print out the student fields in a standard order, regardless
    # of the order they were entered in the hash.
    # Ensure each field is quoted and handle potential undefined values.
    my $string = qq|"| . ($student_hash_ref->{'barcode'} // '')    . qq|",|;
    $string  .= qq|"| . ($student_hash_ref->{'firstName'} // '')  . qq|",|;
    $string  .= qq|"| . ($student_hash_ref->{'middleName'} // '') . qq|",|;
    $string  .= qq|"| . ($student_hash_ref->{'lastName'} // '')   . qq|",|;
    $string  .= qq|"| . ($student_hash_ref->{'street'} // '')     . qq|",|;
    $string  .= qq|"| . ($student_hash_ref->{'city'} // '')       . qq|",|;
    $string  .= qq|"| . ($student_hash_ref->{'state'} // '')      . qq|",|;
    $string  .= qq|"| . ($student_hash_ref->{'zipCode'} // '')    . qq|",|;
    $string  .= qq|"| . ($student_hash_ref->{'birthDate'} // '')  . qq|",|;
    $string  .= qq|"| . ($student_hash_ref->{'email'} // '')      . qq|"|;

    use warnings 'uninitialized'; # Re-enable warnings
    return $string;
}

# Gets max length for string and truncates to fit
sub truncate_field {
    my ($field, $value, $client) = @_;

    my $rule = $client->{'fields'}->{$field}->{'validate'} // '';
    my $type = substr($rule, 0, 1);
    my $data = substr($rule, 2);

    if ($type eq 's') {
        $value = DataHandler::truncate_string($value, $data);
    }

    return $value;
}

# Checks if there is a function to validate a particular field. If there is
# one, it runs it, passing in the value, which will either be returned if it is
# valid or returned as null if it is not (in which case an error may be
# returned by the calling code.
sub validate_field {
    my ($field, $value, $client) = @_;

    # Check for empty fields and return 'null' if found;
    return 'null' unless defined $value && length $value > 0;

    my $rule = $client->{'fields'}->{$field}->{'validate'} // '';
    my $type = substr($rule, 0, 1);
    my $data = substr($rule, 2);

    # If the type is 'c', look for a custom subroutine
    if ($type eq 'c') {
        my $subroutine_name = $data; # e.g., 'validate_zipCode'
        if (defined &{$subroutine_name}) {
            my $subroutine_ref = \&{$subroutine_name};
            # Run the function to check the value
            $value = $subroutine_ref->($value);
        } else {
            logger('error', "Custom validate subroutine '$subroutine_name' not found for field '$field'.");
            $value = ''; # Indicate validation failure
        }
    } elsif (length $rule > 0) {
        if (!DataHandler::validate($value, $rule)) {
            $value = ''; # Indicate validation failure
        }
    }

    return $value;
}

# Checks for valid email address format, returns 'null' if not valid or empty
sub validate_email {
    my $value = shift;
    return 'null' unless defined $value && length $value > 0;

    # Email::Valid->address returns undef on failure, original address on success
    return Email::Valid->address($value) ? $value : 'null';
}

# Validates zipCode as ##### or #####-####.
sub validate_zipCode {
    my $value = shift;
    my $retval = ''; # Default to empty string for invalid

    if (defined $value && ($value =~ /^\d{5}$/ || $value =~ /^\d{5}-\d{4}$/)) {
        $retval = $value;
    }

    return $retval;
}

# Transforms field value using a custom subroutine specified in config.
sub transform_field {
    my ($field, $value, $client, $student_ref, $existing_ref) = @_;

    my $transform_sub_name = $client->{'fields'}->{$field}->{'transform'} // '';

    if (length $transform_sub_name > 0) {
        if (defined &{$transform_sub_name}) {
            my $subroutine_ref = \&{$transform_sub_name};
            # Run the function to transform the value
            # Pass all relevant context for transformations
            $value = $subroutine_ref->($value, $client, $student_ref, $existing_ref);
        } else {
            # Report error
            logger('error', "Custom transform subroutine '$transform_sub_name' not found for field '$field'.");
        }
    }

    return $value;
}

# Transform barcode (prefix with client ID if not already 14 digits and no existing barcode)
sub transform_barcode {
    my ($value, $client, $student, $existing) = @_;

    if (ref $existing eq 'HASH' && defined($existing->{'barcode'}) && $existing->{'barcode'} =~ /^\d{14}$/) {
        $value = $existing->{'barcode'};
    } else {
        $value = $client->{'id'} . $value;
    }

    return $value;
}

# Transform alternateID (set to prefixed barcode if existing barcode is 14 digits)
sub transform_alternateID {
    my ($value, $client, $student, $existing) = @_;

    if (ref $existing eq 'HASH' && defined($existing->{'barcode'}) && $existing->{'barcode'} =~ /^\d{14}$/) {
        $value = $client->{'id'} . ($student->{'barcode'} // '');
    } else {
        # If no existing 14-digit barcode, use the incoming value, but ensure it's defined
        $value = defined $value ? $value : '';
    }

    return $value;
}

# Reformats the date of birth. Accepts dates in two formats:
# MM/DD/YYYY or M/D/YYYY HH:MM:SS AM|PM
# Returns YYYY-MM-DD or empty string on error.
sub transform_birthDate {
    my ($value, $client, $student, $existing) = @_; # Client/student/existing not used, but included for consistency
    my $retval = '';
    my $date_part = '';

    # Extract date part if time is present
    if (defined $value && length($value) > 10 && $value =~ /^(\d{1,2}\/\d{1,2}\/\d{4})/) {
        $date_part = $1;
    } else {
        $date_part = $value;
    }

    if (defined $date_part && length $date_part > 0) {
        my ($year, $mon, $day);
        if (($year, $mon, $day) = Decode_Date_US($date_part)) {
            if (check_date($year, $mon, $day)) {
                $mon = sprintf("%02d", $mon);
                $day = sprintf("%02d", $day);
                $retval = "$year-$mon-$day";
            } else {
                logger('error', "Invalid date ($date_part) in transform_birthDate: Date does not exist (e.g., Feb 30).");
            }
        } else {
            logger('error', "Invalid date ($date_part) in transform_birthDate: Could not decode US date format.");
        }
    } else {
        logger('error', "Empty or undefined birthDate value passed to transform_birthDate.");
    }

    return $retval;
}

# Replaces email with incoming value only if existing email matches a district pattern
# Otherwise, retains the existing email.
sub transform_email {
    my ($value, $client, $student, $existing) = @_; # $client and $student not directly used, but for consistency

    if (defined $value && length $value > 0 &&
        defined $existing && ref $existing eq 'HASH' && defined $existing->{'email'} && length $existing->{'email'} > 0)
    {
        my $match_found = 0;
        my $existing_email = $existing->{'email'};

        # Iterate through all client email patterns in config.yaml
        foreach my $client_config_entry (@{$yaml->[0]->{'clients'} // []}) {
            my $pattern = $client_config_entry->{'email_pattern'};
            if (defined $pattern && length $pattern > 0) {
                my ($username, $domain) = $existing_email =~ /^([^@]+)\@(.+)$/;
                if (defined $domain && $domain eq $pattern) {
                    $match_found = 1;
                    last; # Found a matching pattern
                }
            }
        }
        if (!$match_found) {
            # Existing email does NOT match any configured district pattern, so keep it.
            $value = $existing_email;
        }
    }

    # Ensure a defined value is always returned, even if empty
    return defined $value ? $value : '';
}

# Creates default pin from birthDate (MMDDYYYY)
sub transform_pin {
    my ($value, $client, $student, $existing) = @_; # $value, $client, $existing not used, but for consistency

    my ($year, $mon, $day) = ('1962', '03', '07'); # Default values if birthDate is invalid

    if (defined $student->{'birthDate'} && $student->{'birthDate'} =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        ($year, $mon, $day) = ($1, $2, $3);
    } else {
        logger('error', "Invalid or missing birthDate ('" . ($student->{'birthDate'} // 'undef') . "') in transform_pin. Using default PIN components.");
    }

    return "${mon}${day}${year}";
}

# Selects profile based on age (adult_profile if >= 12 years old)
sub transform_profile {
    my ($value, $client, $student, $existing) = @_; # $value, $client, $existing not used, but for consistency

    my $birthDate = $student->{'birthDate'} // '';
    if (defined $birthDate && $birthDate =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        my ($year1, $month1, $day1) = ($1, $2, $3);
        my ($year2, $month2, $day2) = Today(); # Get current date

        # Adjust for leap year if birthdate is Feb 29 and current year is not a leap year
        if (($day1 == 29) && ($month1 == 2) && !leap_year($year2)) { $day1--; }

        # Calculate age and apply adult profile if 12 or older
        if ((($year2 - $year1) > 12) || ((($year2 - $year1) == 12) && (Delta_Days($year2, $month1, $day1, $year2, $month2, $day2) >= 0))) {
            $value = $yaml->[0]->{'adult_profile'};
        } else {
            # Retain existing value or default if not adult profile
            $value = $value; # Or set to a default child profile if one exists
        }
    } else {
        logger('error', "Invalid or missing birthDate ('" . ($student->{'birthDate'} // 'undef') . "') in transform_profile. Not setting profile based on age.");
    }

    return defined $value ? $value : ''; # Ensure a defined value is returned
}

# Use the AddressFormat.pm function to validate and reformat to USPS standards
sub transform_street {
    my ($value, $client, $student, $existing) = @_; # $client, $student, $existing not used, but for consistency
    return AddressFormat::format_street($value // ''); # Ensure value is defined
}

# Use the AddressFormat.pm function to validate and reformat to USPS standard
sub transform_city {
    my ($value, $client, $student, $existing) = @_; # $client, $student, $existing not used, but for consistency
    return AddressFormat::format_city($value // ''); # Ensure value is defined
}

# Use the AddressFormat.pm function to validate and reformat to USPS standard
sub transform_state {
    my ($value, $client, $student, $existing) = @_; # $client, $student, $existing not used, but for consistency
    return AddressFormat::format_state($value // ''); # Ensure value is defined
}

# Combine the city and state into one field
sub transform_cityState {
    my ($value, $client, $student_ref, $existing) = @_; # $value, $client, $existing not used, but for consistency
    return ($student_ref->{'city'} // '') . ', ' . ($student_ref->{'state'} // ''); # Ensure values are defined
}

# Sets the school district in category03 based on the configuration
sub transform_category03 {
    my ($value, $client_config, $student, $existing) = @_; # $value, $student, $existing not used, but for consistency
    return ($client_config->{'id'} // '') . '-' . ($client_config->{'name'} // ''); # Ensure values are defined
}

# Create a digest (checksum) that can be used when checking if data has
# changed. Sort the keys so that they always appear in the same order,
# regardless of the order they were entered.
sub digest {
    my $data_ref = shift;
    local $Data::Dumper::Sortkeys = 1; # Ensure consistent order for checksum

    unless (ref $data_ref eq 'HASH') {
        logger('error', "digest received non-hash reference.");
        return ''; # Return empty string for invalid input
    }
    return md5_hex(Dumper($data_ref));
}

# Checks for data changes against the checksums database.
# Returns 1 if data has changed or is new, 0 if data is identical.
sub check_for_changes {
    my ($student_hash_ref, $client_config, $dbh) = @_;

    # Construct the barcode used in the database
    my $barcode_for_db = $client_config->{'id'} . ($student_hash_ref->{'barcode'} // '');
    $barcode_for_db =~ s/^0+(?=[0-9])//; # Remove leading zeros, consistent with your original code

    my $data_has_changed = 1; # Default to assume data has changed/is new

    # Create an MD5 digest from the incoming student data
    my $current_checksum = digest($student_hash_ref);
    unless (length $current_checksum > 0) {
        logger('error', "Failed to generate checksum for student " . ($student_hash_ref->{'barcode'} // 'N/A') . ". Assuming data has changed.");
        return 1; # Treat as changed if checksum generation fails
    }

    my $sql_select = qq|SELECT chksum FROM checksums WHERE student_id = ?|;
    my $sth_select;
    eval {
        $sth_select = $dbh->prepare($sql_select);
        $sth_select->execute($barcode_for_db);
    };
    if ($@ || $DBI::errstr) {
        logger('error', "Could not search checksums database for student '$barcode_for_db': " . ($DBI::errstr // $@));
        return 1; # Treat as changed on database error
    }

    my $result_row = $sth_select->fetchrow_hashref;
    $sth_select->finish();

    if (defined $result_row && defined $result_row->{'chksum'}) {
        # We found a checksum record, so we can check if the new data has changed
        if ($current_checksum eq $result_row->{'chksum'}) {
            # The checksums are the same, so the data has not changed
            $data_has_changed = 0;
            $csv_logger->info(qq|"OK","Checksum",| . print_line($student_hash_ref));
        } else {
            # The incoming data has changed, so update the checksum
            my $sql_update = qq|UPDATE checksums SET chksum = ?, date_added = CURDATE() WHERE student_id = ?|;
            my $sth_update;
            eval {
                $sth_update = $dbh->prepare($sql_update);
                $sth_update->execute($current_checksum, $barcode_for_db);
            };
            if ($@ || $DBI::errstr) {
                logger('error', "Could not update checksum for student '$barcode_for_db': " . ($DBI::errstr // $@));
                return 1; # Treat as changed on database error
            }
            logger('debug', "Student data changed, updating checksum database for '$barcode_for_db'.");
        }
    } else {
        # We did not find a checksum record for this student, so we should add one
        my $sql_insert = qq|INSERT INTO checksums (student_id, chksum, date_added) VALUES (?, ?, CURDATE())|;
        my $sth_insert;
        eval {
            $sth_insert = $dbh->prepare($sql_insert);
            $sth_insert->execute($barcode_for_db, $current_checksum);
        };
        if ($@ || $DBI::errstr) {
            logger('error', "Could not add new record to checksums for student '$barcode_for_db': " . ($DBI::errstr // $@));
            return 1; # Treat as changed on database error
        }
        logger('debug', "Inserted new record in checksum database for '$barcode_for_db'.");
    }

    return $data_has_changed;
}

# Connect to checksums database
sub connect_database {
    # Collect configuration data for database connection
    my $mysql_config = $yaml->[0]->{'mysql'};
    unless (defined $mysql_config) {
        error_handler("MySQL configuration not found in config.yaml.");
    }

    my $hostname = $mysql_config->{'hostname'} // 'localhost';
    my $port     = $mysql_config->{'port'}     // 3306;
    my $database = $mysql_config->{'db_name'}  // die "ERROR: 'db_name' not defined in MySQL config.";
    my $username = $mysql_config->{'db_username'} // die "ERROR: 'db_username' not defined in MySQL config.";
    my $password = $mysql_config->{'db_password'} // ''; # Can be empty

    # Connect to the checksums database
    my $dsn = "DBI:mysql:database=$database;host=$hostname;port=$port";
    my $dbh;
    eval {
        $dbh = DBI->connect($dsn, $username, $password, { RaiseError => 0, AutoCommit => 1 });
    };

    if ($@) {
        error_handler("Exception connecting to '$database' database: $@");
    } elsif (!defined $dbh) {
        error_handler("Unable to connect to '$database' database: " . ($DBI::errstr // 'Unknown DBI error.'));
    }

    logger('info', "Login to '$database' database successful.");

    return $dbh;
}

# Get existing record values for all supported fields from ILSWS
sub get_patron {
    my ($token, $barcode) = @_;

    my %patron_data = ();
    my @fields_to_retrieve = (
        'alternateID', 'barcode', 'firstName', 'lastName', 'middleName', 'birthDate', 'pin',
        'profile', 'library',
        # Categories - iterate to get 'category01' through 'category12'
    );
    # Add categories dynamically
    for my $i (1 .. 12) {
        push @fields_to_retrieve, sprintf("category%02d", $i);
    }
    push @fields_to_retrieve, 'address1'; # To retrieve nested address fields

    my %address_field_map = (
        'STREET'     => 'street',
        'CITY/STATE' => 'cityState',
        'ZIP'        => 'zipCode',
        'PHONE'      => 'telephone',
        'EMAIL'      => 'email'
    );

    my $field_list_str = join(',', @fields_to_retrieve);
    my %options = (ct => 1, includeFields => $field_list_str); # Limit to 1 result, as we search by barcode/ID

    my $ils_response;
    eval {
        $ils_response = ILSWS::patron_search($token, 'ID', $barcode, \%options);
    };

    if ($@) {
        logger('error', "Exception during ILSWS::patron_search for barcode '$barcode': $@");
        return \%patron_data; # Return empty hash on error
    } elsif (!defined $ils_response || ($ILSWS::code && $ILSWS::code != 200)) {
        logger('error', "ILSWS::patron_search failed for barcode '$barcode': " . ($ILSWS::code // 'N/A') . ": " . ($ILSWS::error // 'No specific error message.'));
        return \%patron_data; # Return empty hash on API error
    }

    if ($ils_response->{'totalResults'} >= 1 && defined $ils_response->{'result'}->[0]->{'fields'}) {
        my $patron_ils_fields = $ils_response->{'result'}->[0]->{'fields'};

        # Get the simple string fields
        foreach my $field ('alternateID','barcode','firstName','lastName','middleName','birthDate','pin') {
            $patron_data{$field} = $patron_ils_fields->{$field} // '';
        }

        # Get the resource items (library, profile)
        foreach my $field ('library','profile') {
            $patron_data{$field} = $patron_ils_fields->{$field}->{'key'} // '';
        }

        # Get the category items (category01 to category12)
        for my $i (1 .. 12) {
            my $cat_field = sprintf("category%02d", $i);
            $patron_data{$cat_field} = $patron_ils_fields->{$cat_field}->{'key'} // '';
        }

        # Get address fields from address1 array
        if (defined $patron_ils_fields->{'address1'} && ref $patron_ils_fields->{'address1'} eq 'ARRAY') {
            for (my $i = 0; $i <= $#{$patron_ils_fields->{'address1'}}; $i++) {
                my $address_entry = $patron_ils_fields->{'address1'}->[$i];
                if (defined $address_entry->{'fields'}->{'code'}->{'key'} &&
                    defined $address_field_map{$address_entry->{'fields'}->{'code'}->{'key'}})
                {
                    my $mapped_field_name = $address_field_map{$address_entry->{'fields'}->{'code'}->{'key'}};
                    $patron_data{$mapped_field_name} = $address_entry->{'fields'}->{'data'} // '';
                }
            }
        }
    } else {
        logger('debug', "No existing patron found for barcode '$barcode' or response malformed.");
    }

    return \%patron_data;
}
