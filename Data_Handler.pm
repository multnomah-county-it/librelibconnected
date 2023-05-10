package Data_Handler;

# Copyright (c) Multnomah County (Oregon)
#
# Module for handling data mapping and validation for reports
#
# John Houser
# john.houser@multco.us
#
# 2022-06-10

# Pragmas
use strict;
use warnings;

# Required modules
use JSON;
use Text::CSV_XS qw(csv);
use File::Basename qw(basename);
use File::Find;
use Date::Calc qw(check_date Today_and_Now);
use Switch;
use base 'Exporter';

our @EXPORT = qw(load_maps evaluate_map validate validate_date);

# Set to 1 for dubugging messages
our $debug = 0;

# The data structure containing maps
our %MAPS = ();

#################################################################################

#################################################################################
# Find mapping table files in specific directory and load them into memory 
# as hashes we can evaluate in &evaluate_map

sub load_maps {
	my $mapping_path = shift;

	find(\&wanted, $mapping_path);
}

#################################################################################

#################################################################################
# Load individual mapping file into memory as hash

sub wanted {
	my $mapping_file = $_;

	my $basename = basename($mapping_file);

	if ( $basename =~ /^Data_Handler-(.*)\.csv$/ ) {
		my $field = $basename;
		$field =~ s/^(Data_Handler-)(.*)(\.csv)$/$2/;

		my $csv = Text::CSV_XS->new();
		my $count = 0;
		my @columns = ();

		open my $fh, "<:encoding(utf8)", $mapping_file or die "Could not open mapping file: $!";
		while ( my $row = $csv->getline ($fh) ) {
			foreach my $i ( 0 .. $#{$row} ) {
				if ( $count == 0 ) {
					$MAPS{$field}[$count][$i] = $row->[$i];
				} else {
					$MAPS{$field}[$count]{$MAPS{$field}[0][$i]} = $row->[$i];
				}
			}
			$count++;
		}
		close $fh;
	}
}

#################################################################################

#################################################################################
# Evaluate mapping hash to determine output value. Each mapping file must consist
# of a hash something like this:
#
# %Cost_Center = (
#      [ 'Organization', 'Department', 'Cost_Center' ],
#      {
#         Organization  => 'Waffle Makers, Ltd.',
#         Department    => 'Accounting',
#         Cost_Center   => 813510
#      },
#      {
#         Organization  => 'Waffle Makers, Ltd.',
#         Department    => 'IT',
#         Cost_Center   => 813520
#      },
#   );
#
# If the input hash contains Organization which equals "Waffle Makers, Ltd.", and
# the input hash contains Department which equals "Accounting", then return
# a value of 813510.

sub evaluate_map {
	my $input_hashref = shift;
	my $map = shift; 

  # Get the output field from the last column in $map->[0];
	my $field = $map->[0][$#{$map->[0]}];
	my $retval = '';

	foreach my $i ( 1 .. $#{$map} ) {

		my $match = 0;
		foreach my $key ( keys %{$map->[$i]} ) {

			if ( defined($input_hashref->{$key}) && $input_hashref->{$key} eq $map->[$i]{$key} ) {
				print "input: $input_hashref->{$key}, map: $map->[$i]{$key}\n" if ( $debug );
				$match++;
			}
		}
		
		# If we matched every column, then return output field value
		if ( $match == $#{$map->[0]} ) {
			$retval = $map->[$i]->{$field};
			last;
		}
	}

	return $retval;
}

#################################################################################

#################################################################################
# Validates various types of incoming field data
# Sample fields hash with validation rules:
#
# %fields = (
#	Date1                      => 'd:YYYY-MM-DD',
#	Date2                      => 'd:YYYY/MM/DD',
#	Date3                      => 'd:MM-DD-YYYY',
#	Date4                      => 'd:MM/DD/YYYY',
#	Timestamp1                 => 'd:YYYY/MM/DD HH:MM',
#	Timestamp2                 => 'd:YYYY-MM-DD HH:MM',
#   Timestamp3                 => 'd:YYYYMMDDHHMMSS',
#	Customer_Reference         => 'i:8',                # int(8)
#	Invoice_Memo               => 's:256',              # string(256)
#	Posting                    => 'v:01|11',            # list('01', '11')
#	Customer_PO_Number         => 'b',                  # must be blank
#	Extended_Amount            => 'n:3.2',              # number(000.00)
#   Range                      => 'r:100000,999999',    # integer between x and y
#	);
#
# Returns 0 or 1

sub validate {
	my $value = shift;
	my $validation_rule = shift;

	my $retval = 0;
	my ($type, $param) = split /:/, $validation_rule, 2;

	switch($type) {
		case ('b') {
			# Value be undefined
			if ( ! defined($value) ) {
				$retval = 1;
			}
		}
		case ('d') {
			# Send to date validation routine
			if ( $value && &validate_date($value, $param) ) {
				$retval = 1;
			}
		}
		case ('i') {
			# Must be an integer of length specified
			if ( $value && $value =~ /^\d+$/ && length($value) <= $param ) {
				$retval = 1;
			}
		}
		case ('n') {
			# Number of specific lengths in both the whole and fractional parts.
			# Most numbers of this type will need to be sent through sprintf
			# before being validated. Zero is acceptable but undefined will
			# return invalid.
			my ($whole_len, $frac_len) = split /\./, $param;
			if ( $value && $value =~ /^\d+\.\d+$/ ) {
				my ($whole, $frac) = split /\./, scalar($value);
				if ( length($whole) <= $whole_len && length($frac) <= $frac_len ) {
					$retval = 1;
				}
			} elsif ( $value && $value =~ /^\d+$/ ) {
				if ( length($value) <= $whole_len ) {
					$retval = 1;
				}
			}
		}
		case ('s') {
			# String no larger than specified length. Strings are allowed to be blank.
			if ( ! defined($value) || length($value) <= $param ) {
				$retval = 1;
			}
		}
		case ('r') {
			# Integer range between x and y
			my ($x, $y) = split /,/, $param;
			if ( $value >= $x && $value <= $y ) {
				$retval = 1;
			}
		}
		case ('v') {
			# Value must match one of those listed in | delimited form in the parameter.
			if ( $value ) {
				my @params = split /\|/, $param;
				foreach my $param ( @params ) {	
					if ( $value eq $param ) {
						$retval = 1;
						last;
					}
				}
			}
		}
		else {
			die "No validation rule for type $type";
		}
	}

	return $retval;
}

################################################################################

################################################################################
# Validates various date formats. Returns nothing or the valid date in 
# YYYY-MM-DD format.

sub validate_date {
	my $date = shift;
	my $format = shift;

	my $retval = '';

	switch($format) {
		case ( /^(YYYY)([\-\/]){1}(MM)([\-\/]){1}(DD\sHH:MM)$/ ) {
			if ( $date =~ /^\d{4}[\-\/]{1}\d{2}[\-\/]{1}\d{2}\s\d{2}:\d{2}$/ ) {
				my ($year, $month, $day, $time) = split /[\-\/\s]/, $date;
				if ( check_date($year, $month, $day) ) {
					$retval = $year . '-' . sprintf("%02d", $month) . '-' . sprintf("%02d", $day);
				}
			}
		}
		case ( /^(YYYY)([\-\/]{1})(MM)([\-\/]{1})(DD)$/ ) {
			if ( $date =~ /^\d{4}[\-\/]{1}\d{2}[\-\/]{1}\d{2}(\s\d{2}:\d{2}){0,1}$/ ) {
				my ($year, $month, $day) = split /[\-\/]/, $date;
				if ( check_date($year, $month, $day) ) {
					$retval = $year . '-' . sprintf("%02d", $month) . '-' . sprintf("%02d", $day);
				}
			}
		}
		case ( /^(MM)([\-\/]{1})(DD)([\-\/]{1})(YYYY)$/ ) {
			if ( $date =~ /^(\d{2})([\-\/]{1})(\d{2})([\-\/]{1})(\d{4})$/ ) {
				my ($month, $day, $year) = split /[\-\/]/, $date;
				if ( check_date($year, $month, $day) ) {
					$retval = $year . '-' . sprintf("%02d", $month) . '-' . sprintf("%02d", $day);
				}
			}
		}
		case ( /^YYYYMMDDHHMMSS$/ ) {
			if ( $date =~ /^\d{14}$/ ) {
				my $year = substr $date, 0, 4;
				my $month = substr $date, 4, 2;
				my $day = substr $date, 6, 2;
				if ( check_date($year, $month, $day) ) {
					$retval = $year . '-' . sprintf("%02d", $month) . '-' . sprintf("%02d", $day);
				}
			}
		}
		case ( /^YYYYMMDD$/ ) {
			if ( $date =~ /^\d{8}$/ ) {
				my $year = substr $date, 0, 4;
				my $month = substr $date, 4, 2;
				my $day = substr $date, 6, 2;
				if ( check_date($year, $month, $day) ) {
					$retval = $year . '-' . sprintf("%02d", $month) . '-' . sprintf("%02d", $day);
				}
			}
		}
		else {
			die "Unsupported date format: $format";
		}
	}

	return $retval;
}

###############################################################################

###############################################################################

1;
