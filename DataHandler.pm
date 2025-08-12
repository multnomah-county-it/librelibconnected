package DataHandler;

# Copyright (c) Multnomah County (Oregon)
#
# Module for handling data mapping and validation for reports.
#
# Author: John Houser (john.houser@multco.us)
# Date: 2022-06-10

# Pragmas
use strict;
use warnings;
use utf8; # For proper handling of Unicode characters in data and file paths

# Standard Exporter setup for Perl modules
use Exporter qw(import);
our @ISA = qw(Exporter);
our @EXPORT = qw(load_maps evaluate_map validate validate_date truncate_string);

# Required modules
use JSON; # Used for JSON encoding/decoding, though not directly in the provided snippets.
use Text::CSV_XS; # For robust CSV parsing
use File::Basename qw(basename); # For extracting base filename
use File::Find; # For traversing directories to find mapping files
use Date::Calc qw(check_date); # For date validation (Today_and_Now not used in snippets)

# --- Module-level Variables ---
# Use 'my' for lexical variables where possible.
# For module-level shared data, `our` can be used, but generally minimize global state.
# `%MAPS` is a module-level global, used to store loaded mappings.
our %MAPS = ();
my $DEBUG = 0; # Set to 1 for debugging messages, 0 for production.

# Internal logging helper (simple print to STDERR for this module)
sub _log_debug {
    my $message = shift;
    warn "DataHandler DEBUG: $message\n" if $DEBUG;
}

sub _log_error {
    my $message = shift;
    warn "DataHandler ERROR: $message\n";
}

=head1 NAME

DataHandler - Perl package for data mapping and validation.

=head1 SYNOPSIS

  use DataHandler;

  # Load mapping tables from a directory
  DataHandler::load_maps('/path/to/mapping/files');

  # Evaluate data against a loaded map
  my %input_data = (
      Organization => 'Waffle Makers, Ltd.',
      Department   => 'Accounting'
  );
  my $cost_center = DataHandler::evaluate_map(\%input_data, $DataHandler::MAPS{'Cost_Center'});

  # Validate data using predefined rules
  my $is_valid = DataHandler::validate('some_value', 's:256');

  # Validate and format a date
  my $formatted_date = DataHandler::validate_date('10/25/2023', 'MM/DD/YYYY');

  # Truncate a string
  my $truncated_string = DataHandler::truncate_string('This is a very long string', 10);

=head1 DESCRIPTION

This module provides utilities for handling common data transformation and
validation tasks. It includes functionality to load mapping tables from
CSV files, evaluate input data against these mappings, and validate various
data types (dates, integers, strings, numbers, ranges, lists) against
specified rules. It also offers a utility for truncating strings.

=head1 SUBROUTINES

=cut

=head2 load_maps($mapping_path)

Scans a specified directory for CSV mapping files (named `Data_Handler-FIELDNAME.csv`)
and loads their content into the module's internal `%MAPS` hash.
Each mapping file is expected to be a CSV where the first row contains column headers,
and subsequent rows contain data. The last column in each CSV is treated as the
output field.

The loaded map for a given FIELDNAME will be accessible as `$DataHandler::MAPS{FIELDNAME}`.

=head3 Parameters

=over 4

=item $mapping_path (string) - The absolute path to the directory containing mapping CSV files.

=back

=head3 Returns

None. Populates the global `%DataHandler::MAPS` hash. Dies if the mapping path is invalid
or if a mapping file cannot be opened.

=cut
sub load_maps {
    my $mapping_path = shift;

    unless (defined $mapping_path && -d $mapping_path && -r $mapping_path) {
        _log_error("Invalid or unreadable mapping path provided: '$mapping_path'");
        die "Cannot load maps: Invalid mapping directory.\n";
    }

    _log_debug("Scanning for mapping files in: '$mapping_path'");

    # Use a localized copy of `$_` within the `wanted` subroutine to prevent
    # unintended modifications to the global `$_` if it's used elsewhere by File::Find's caller.
    File::Find::find(sub { _wanted_callback($File::Find::name) }, $mapping_path);

    _log_debug("Finished loading maps. Loaded " . (keys %MAPS) . " maps.");
}

# _wanted_callback: Internal subroutine used by File::Find to process each file found.
# It attempts to load CSV files matching the naming convention into %MAPS.
# Named with underscore prefix to indicate it's an internal helper.
sub _wanted_callback {
    my $file_path = shift;

    # Localize `$_` for safety within File::Find's callback context if needed
    local $_ = $file_path;

    my $basename = basename($_);

    if (-f $_ && $basename =~ /^Data_Handler-(.*)\.csv$/) {
        my $field_name = $1; # Capture the field name from the filename

        my $csv_parser = Text::CSV_XS->new({ binary => 1, auto_diag => 1, sep_char => ',' });
        $csv_parser->encoding('utf8'); # Assume CSV files are UTF-8 encoded

        _log_debug("Attempting to load mapping file: '$file_path' for field: '$field_name'");

        my $fh;
        unless (open $fh, "<:encoding(utf8)", $file_path) {
            _log_error("Could not open mapping file '$file_path': $!");
            die "Failed to open mapping file.\n"; # Fatal for critical resource
        }

        my @map_rows;
        my @header;

        # Read header row
        if (my $row_ref = $csv_parser->getline($fh)) {
            @header = @{$row_ref};
            push @map_rows, [@header]; # Store header as the first element (array ref)
        } else {
            _log_error("Mapping file '$file_path' is empty or has no header.");
            close $fh;
            return; # Skip to next file
        }

        # Read data rows and convert to hash references using header
        while (my $row_ref = $csv_parser->getline($fh)) {
            my %row_data;
            foreach my $col_idx (0 .. $#header) {
                $row_data{$header[$col_idx]} = $row_ref->[$col_idx];
            }
            push @map_rows, \%row_data; # Store data rows as hash references
        }
        close $fh;

        $MAPS{$field_name} = \@map_rows; # Store the array reference to the map rows
        _log_debug("Successfully loaded map for '$field_name'.");
    }
}

=head2 evaluate_map($input_hash_ref, $map_array_ref)

Evaluates an input hash against a loaded mapping table to determine an output value.
The mapping table (`$map_array_ref`) is expected to be an array of arrays/hashes,
as produced by `load_maps`. The first element is an array of column headers,
and subsequent elements are hash references where keys are column headers and values are data.

The function iterates through the data rows of the map. For each row, if all
corresponding keys in the `$input_hash_ref` match the values in that map row,
the value from the *last column* of that map row is returned.

Example of map structure (conceptually, as loaded):
  [
    ['Organization', 'Department', 'Cost_Center'], # Header row
    { Organization => 'Waffle Makers, Ltd.', Department => 'Accounting', Cost_Center => 813510 },
    { Organization => 'Waffle Makers, Ltd.', Department => 'IT', Cost_Center => 813520 },
  ]

=head3 Parameters

=over 4

=item $input_hash_ref (hash reference) - A hash containing input keys and values to match.
=item $map_array_ref (array reference) - A reference to a loaded mapping table (e.g., `$DataHandler::MAPS{'FIELDNAME'}`).

=back

=head3 Returns

The matching output value (from the last column of the matched map row) on success.
Returns an empty string (`''`) if no match is found or if input is invalid.

=cut
sub evaluate_map {
    my ($input_hash_ref, $map_array_ref) = @_;

    # Input validation
    unless (defined $input_hash_ref && ref $input_hash_ref eq 'HASH') {
        _log_error("Invalid input hash reference provided to evaluate_map.");
        return '';
    }
    unless (defined $map_array_ref && ref $map_array_ref eq 'ARRAY' && scalar @$map_array_ref >= 1) {
        _log_error("Invalid map array reference provided to evaluate_map.");
        return '';
    }

    my $header_row = $map_array_ref->[0]; # Get the header row (array reference)
    unless (defined $header_row && ref $header_row eq 'ARRAY' && scalar @$header_row >= 1) {
        _log_error("Map array reference has malformed header row.");
        return '';
    }

    # The output field is the value in the last column of the header.
    my $output_field_name = $header_row->[$#{$header_row}];
    my $num_comparison_fields = scalar(@{$header_row}) - 1; # Number of fields to compare against

    _log_debug("Evaluating map for output field: '$output_field_name'");

    # Iterate from the first data row (index 1) to the end of the map.
    foreach my $row_idx (1 .. $#{$map_array_ref}) {
        my $map_row_data_ref = $map_array_ref->[$row_idx];
        unless (defined $map_row_data_ref && ref $map_row_data_ref eq 'HASH') {
            _log_debug("Skipping malformed map row at index $row_idx (not a hash reference).");
            next;
        }

        my $match_count = 0;
        my $all_comparison_fields_match = 1;

        # Iterate through all fields in the map row, except the last one (output field).
        foreach my $col_name (@{$header_row}[0 .. $#{$header_row}-1]) { # Compare all fields except the last one
            my $input_val = $input_hash_ref->{$col_name};
            my $map_val = $map_row_data_ref->{$col_name};

            if (defined $input_val && defined $map_val && $input_val eq $map_val) {
                _log_debug("Matched '$col_name': input '$input_val' == map '$map_val'");
                $match_count++;
            } else {
                _log_debug("No match for '$col_name': input '" . ($input_val // 'undef') . "' vs map '" . ($map_val // 'undef') . "'");
                $all_comparison_fields_match = 0;
                last; # No need to check other fields in this row, it's not a full match
            }
        }

        # If we matched every comparison column, then return the output field value.
        if ($all_comparison_fields_match && $match_count == $num_comparison_fields) {
            my $result_value = $map_row_data_ref->{$output_field_name};
            _log_debug("Full match found. Returning value: '" . ($result_value // 'undef') . "'");
            return defined $result_value ? $result_value : '';
        }
    }

    _log_debug("No match found in map.");
    return ''; # No match found
}

=head2 validate($value, $validation_rule)

Validates various types of incoming field data against a specified rule.
Validation rules are strings with a type code and an optional parameter, separated by a colon.

Supported Validation Rules:
=over 4

=item * B<b:> (Blank) - Value must be undefined or empty string.
=item * B<d:FORMAT> (Date) - Value must be a valid date in the specified FORMAT (e.g., YYYY-MM-DD, MM/DD/YYYY).
                          Delegates to `validate_date`.
=item * B<i:LENGTH> (Integer) - Value must be an integer, and its string length must be less than or equal to LENGTH.
=item * B<n:WHOLE.FRACTION> (Number) - Value must be a number with up to WHOLE digits before the decimal and FRACTION digits after.
                                    Handles integers or decimals.
=item * B<s:LENGTH> (String) - Value must be a string, and its length must be less than or equal to LENGTH.
                            Empty strings are allowed.
=item * B<r:MIN,MAX> (Range) - Value must be an integer within the inclusive range of MIN to MAX.
=item * B<v:VAL1|VAL2|...> (Value List) - Value must exactly match one of the pipe-delimited values in the parameter.

=back

=head3 Parameters

=over 4

=item $value (scalar) - The data value to validate.
=item $validation_rule (string) - The rule string (e.g., 's:256', 'd:YYYY-MM-DD').

=back

=head3 Returns

True (1) if the value is valid according to the rule, false (0) otherwise.
Dies if an unsupported validation rule type is provided.

=cut
sub validate {
    my ($value, $validation_rule) = @_;

    unless (defined $validation_rule && length $validation_rule > 0) {
        _log_error("No validation rule provided for value: '" . ($value // 'undef') . "'");
        return 0;
    }

    my ($type, $param) = split /:/, $validation_rule, 2;
    my $is_valid = 0; # Default to invalid

    if ($type eq 'b') { # Blank
        # Value must be undefined or an empty string
        if (!defined $value || length($value) == 0) {
            $is_valid = 1;
        }
        _log_debug("Validation 'b': Value '" . ($value // 'undef') . "' is " . ($is_valid ? 'valid' : 'invalid'));
    } elsif ($type eq 'd') { # Date
        # Send to date validation routine
        if (defined $value && length $value > 0 && validate_date($value, $param)) {
            $is_valid = 1;
        }
        _log_debug("Validation 'd:$param': Value '" . ($value // 'undef') . "' is " . ($is_valid ? 'valid' : 'invalid'));
    } elsif ($type eq 'i') { # Integer
        # Must be an integer of length specified
        my $max_length = defined $param ? int($param) : 0;
        if (defined $value && $value =~ /^-?\d+$/ && length($value) <= $max_length) {
            $is_valid = 1;
        }
        _log_debug("Validation 'i:$max_length': Value '" . ($value // 'undef') . "' is " . ($is_valid ? 'valid' : 'invalid'));
    } elsif ($type eq 'n') { # Number (whole and fractional parts)
        # Number with specific lengths in both the whole and fractional parts.
        # Zero is acceptable but undefined will return invalid.
        my ($whole_len, $frac_len) = split /\./, $param, 2;
        $whole_len = int($whole_len // 0);
        $frac_len  = int($frac_len  // 0);

        if (defined $value) {
            # Try to handle common number formats (e.g., "123", "123.45", "-123.45")
            if ($value =~ /^(-?\d+)(?:\.(\d+))?$/) {
                my $whole = $1;
                my $frac  = defined $2 ? $2 : '';

                if (length($whole) <= $whole_len && length($frac) <= $frac_len) {
                    $is_valid = 1;
                }
            }
        }
        _log_debug("Validation 'n:$param': Value '" . ($value // 'undef') . "' is " . ($is_valid ? 'valid' : 'invalid'));
    } elsif ($type eq 's') { # String
        # String no larger than specified length. Strings are allowed to be blank.
        my $max_length = defined $param ? int($param) : 0;
        if (!defined $value || length($value) <= $max_length) {
            $is_valid = 1;
        }
        _log_debug("Validation 's:$max_length': Value '" . ($value // 'undef') . "' is " . ($is_valid ? 'valid' : 'invalid'));
    } elsif ($type eq 'r') { # Range (integer between x and y)
        my ($min_val, $max_val) = split /,/, $param, 2;
        $min_val = defined $min_val ? int($min_val) : "-Inf"; # Use -Inf for open lower bound
        $max_val = defined $max_val ? int($max_val) : "+Inf"; # Use +Inf for open upper bound
        
        if (defined $value && $value =~ /^-?\d+$/) {
            my $numeric_value = int($value);
            if ($numeric_value >= $min_val && $numeric_value <= $max_val) {
                $is_valid = 1;
            }
        }
        _log_debug("Validation 'r:$param': Value '" . ($value // 'undef') . "' is " . ($is_valid ? 'valid' : 'invalid'));
    } elsif ($type eq 'v') { # Value list
        # Value must match one of those listed in | delimited form in the parameter.
        if (defined $value && length $value > 0) {
            my @allowed_values = split /\|/, $param;
            foreach my $allowed_val (@allowed_values) {
                if ($value eq $allowed_val) {
                    $is_valid = 1;
                    last;
                }
            }
        }
        _log_debug("Validation 'v:$param': Value '" . ($value // 'undef') . "' is " . ($is_valid ? 'valid' : 'invalid'));
    } else {
        _log_error("Unsupported validation rule type: '$type' for rule '$validation_rule'.");
        die "Unsupported validation rule type encountered.\n";
    }

    return $is_valid;
}

=head2 validate_date($date, $format)

Validates various date formats.
Returns the valid date formatted as 'YYYY-MM-DD' on success, or an empty string ('') on failure.

Supported Date Formats (case-insensitive where applicable):
=over 4

=item * B<YYYY-MM-DD HH:MM> or B<YYYY/MM/DD HH:MM>
=item * B<YYYY-MM-DD> or B<YYYY/MM/DD>
=item * B<MM-DD-YYYY> or B<MM/DD/YYYY>
=item * B<YYYYMMDDHHMMSS>
=item * B<YYYYMMDD>

=back

=head3 Parameters

=over 4

=item $date (string) - The date string to validate.
=item $format (string) - The expected format of the date string.

=back

=head3 Returns

The formatted date string ('YYYY-MM-DD') on success, or an empty string (`''`) on failure.
Dies if an unsupported date format rule is provided.

=cut
sub validate_date {
    my ($date, $format) = @_;

    unless (defined $date && defined $format) {
        _log_debug("validate_date received undefined date or format.");
        return '';
    }

    my $retval = ''; # Default return value

    # Normalize format string for comparison
    my $norm_format = uc($format);

    if ($norm_format =~ m{^YYYY[/\-]?MM[/\-]?DD\sHH:MM$}) {
        # YYYY-MM-DD HH:MM or YYYY/MM/DD HH:MM
        if ($date =~ /^(\d{4})[\/\-](\d{2})[\/\-](\d{2})\s(\d{2}):(\d{2})$/) {
            my ($year, $month, $day) = ($1, $2, $3);
            if (check_date($year, $month, $day)) {
                $retval = sprintf("%s-%02d-%02d", $year, $month, $day);
            }
        }
    } elsif ($norm_format =~ m{^YYYY[/\-]?MM[/\-]?DD$}) {
        # YYYY-MM-DD or YYYY/MM/DD (optional time part allowed in input, but ignored)
        if ($date =~ /^(\d{4})[\/\-](\d{2})[\/\-](\d{2})(?:\s\d{2}:\d{2}){0,1}$/) {
            my ($year, $month, $day) = ($1, $2, $3);
            if (check_date($year, $month, $day)) {
                $retval = sprintf("%s-%02d-%02d", $year, $month, $day);
            }
        }
    } elsif ($norm_format =~ m{^MM[/\-]?DD[/\-]?YYYY$}) {
        # MM-DD-YYYY or MM/DD/YYYY
        if ($date =~ /^(\d{2})[\/\-](\d{2})[\/\-](\d{4})$/) {
            my ($month, $day, $year) = ($1, $2, $3);
            if (check_date($year, $month, $day)) {
                $retval = sprintf("%s-%02d-%02d", $year, $month, $day);
            }
        }
    } elsif ($norm_format eq 'YYYYMMDDHHMMSS') {
        # YYYYMMDDHHMMSS
        if ($date =~ /^(\d{4})(\d{2})(\d{2})\d{6}$/) { # Capture YYYYMMDD, ignore HHMMSS
            my ($year, $month, $day) = ($1, $2, $3);
            if (check_date($year, $month, $day)) {
                $retval = sprintf("%s-%02d-%02d", $year, $month, $day);
            }
        }
    } elsif ($norm_format eq 'YYYYMMDD') {
        # YYYYMMDD
        if ($date =~ /^(\d{4})(\d{2})(\d{2})$/) {
            my ($year, $month, $day) = ($1, $2, $3);
            if (check_date($year, $month, $day)) {
                $retval = sprintf("%s-%02d-%02d", $year, $month, $day);
            }
        }
    } else {
        _log_error("Unsupported date format rule: '$format'.");
        die "Unsupported date format rule.\n";
    }

    _log_debug("Date validation for '$date' with format '$format': Result '" . ($retval // 'undef') . "'");
    return $retval;
}

=head2 truncate_string($value, $length)

Truncates a string to a specified maximum length.
If the string contains spaces, it truncates at the nearest word boundary.
If the string contains no spaces, it truncates character by character.
It appends a '$' character to truncated strings (this behavior should be explicitly
understood by callers).

=head3 Parameters

=over 4

=item $value (string) - The string to truncate.
=item $length (integer) - The maximum desired length of the string.

=back

=head3 Returns

The truncated string. If the input string is already shorter than or equal to
the specified length, it is returned unchanged. Returns an empty string if
input is undefined.

=cut
sub truncate_string {
    my ($value, $length) = @_;

    # Return empty string if input is not defined
    return '' unless defined $value;

    # Return original value if it's already within length
    return $value if length($value) <= $length;

    my $truncated_value = $value;

    if ($truncated_value =~ /\s/) { # Contains spaces, try to truncate at word boundary
        my @parts = split /\s+/, $truncated_value;
        # Pop parts until the length constraint is met
        while (length(join(' ', @parts)) > $length && @parts > 0) {
            pop @parts;
        }
        $truncated_value = join ' ', @parts;

        # If after word truncation it's still too long (e.g., a single very long word),
        # or if it truncated to empty, then do character-by-character truncation.
        if (length($truncated_value) > $length || length($truncated_value) == 0 && length($value) > 0) {
             # Fallback to character-by-character if word boundary truncation failed to meet length
             $truncated_value = substr($value, 0, $length);
        }

    } else { # No spaces, truncate character by character
        $truncated_value = substr($truncated_value, 0, $length);
    }

    # Append '$' character if truncation actually occurred
    if (length($value) > $length) {
        $truncated_value .= '$';
    }

    _log_debug("Truncated string from '" . $value . "' (length " . length($value) . ") to '" . $truncated_value . "' (length " . length($truncated_value) . ", target $length)");
    return $truncated_value;
}

# End of package. Returns a true value.
1;
