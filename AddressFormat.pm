package AddressFormat;

# This package provides routines for formatting address elements (street, city, state)
# to conform with common postal guidelines, particularly useful for USPS standards.

use strict;
use warnings;
use Readonly; # A common practice for true constants (optional, but good for SEI CERT)

# --- Module-level Constants ---
# Use Readonly for immutable constants, or 'my' for lexical variables.
# Readonly is preferred for global, true constants.
Readonly my $DEBUG_LEVEL => 0; # Internal debug level for this module (0=off, 1=basic, etc.)

# --- Public Subroutines ---

=head1 NAME

AddressFormat - Perl package for formatting address elements to USPS standards.

=head1 SYNOPSIS

  use AddressFormat;

  my $formatted_street = AddressFormat::format_street("123 main ST. apt #4B");
  my $formatted_city   = AddressFormat::format_city("new york  city ");
  my $formatted_state  = AddressFormat::format_state("oregon");

=head1 DESCRIPTION

This package contains subroutines to clean and standardize various components
of a postal address, primarily for use in systems that require USPS-compliant
address formats. It handles trimming whitespace, removing punctuation,
standardizing abbreviations, and correcting common misspellings or
capitalization issues.

=head1 SUBROUTINES

=cut

=head2 format_street($value)

Formats a street address string to conform to USPS guidelines.
This includes:
=over 4

=item * Trimming leading/trailing whitespace.
=item * Removing periods and commas.
=item * Standardizing spacing around '#' signs.
=item * Applying title capitalization (words > 4 chars, or not all caps).
=item * Correcting common street name variations (e.g., "Cesar Chavez").
=item * Standardizing compass directions (e.g., "N", "SE").
=item * Abbreviating common street types (e.g., "Avenue" to "Ave").
=item * Fixing capitalization of common abbreviations.
=item * Standardizing apartment/building descriptors.
=item * Correcting specific street name misspellings or formats.
=item * Formatting numbered street names (e.g., "1st", "11th").

=back

=head3 Parameters

=over 4

=item $value (string) - The raw street address string to format.

=back

=head3 Returns

The formatted street address string. Returns an empty string if the input is undefined.

=cut
sub format_street {
    my $value = shift;

    # Return empty string if input is not defined to avoid undef warnings
    return '' unless defined $value;

    # Trim leading or trailing spaces
    $value =~ s/^\s+|\s+$//g;

    # Remove periods and commas
    $value =~ s/[\.,]//g;

    # Space # signs per USPS guidelines: " # " rather than "#" or " #"
    $value =~ s/\s*\#\s*/ # /g;
    $value =~ s/^#\s*/# /; # Handle leading '#' without leading space

    # Title capitalization: Convert to lowercase, then capitalize the first letter of each word.
    # Words with more than one uppercase or length <= 4 are assumed to be acronyms or short words
    # that should retain their original case (e.g., "C/O").
    my @words = split /\s+/, $value;
    foreach my $word_idx (0 .. $#words) {
        my $word = $words[$word_idx];
        if ($word !~ /[A-Z]{2,}/ || length($word) <= 4) { # If not multiple uppercase, or is a short word
            $word = lc($word);
            $word = ucfirst($word);
        }
        $words[$word_idx] = $word;
    }
    $value = join ' ', @words;

    # Correct specific street names
    $value =~ s/Cesar Chavez/Cesar E Chavez/gi;
    $value =~ s/Martin Luther King Jr/ML King/gi;
    $value =~ s/MLK Jr/ML King/gi;
    $value =~ s/MLK/ML King/gi;
    $value =~ s/BRdway(?=\s|$)/Broadway/gi;

    # Special cases (e.g., C/O, PO Box) - maintain specific capitalization
    $value =~ s#c/o(?=\s|$)#C/O#gi; # Use # as delimiter for regex to avoid escaping /
    $value =~ s/^po box(?=\s+)/PO Box/gi;
    $value =~ s/\s+bkvd(?=\s|$)/ Blvd/gi; # Common typo fix

    # Standardize compass regions (e.g., N, NE) - ensure space before abbreviation
    $value =~ s/\s+N(?=\s|$)/ N/gi;
    $value =~ s/\s+NE(?=\s|$)/ NE/gi;
    $value =~ s/\s+NW(?=\s|$)/ NW/gi;
    $value =~ s/\s+S(?=\s|$)/ S/gi;
    $value =~ s/\s+SE(?=\s|$)/ SE/gi;
    $value =~ s/\s+SW(?=\s|$)/ SW/gi;

    # Abbreviate and capitalize street types (full word to abbreviation)
    $value =~ s/\s+avenue(?=\s|$)/ Ave/gi;
    $value =~ s/\s+boulevard(?=\s|$)/ Blvd/gi;
    $value =~ s/\s+court(?=\s|$)/ Ct/gi;
    $value =~ s/\s+drive(?=\s|$)/ Dr/gi;
    $value =~ s/\s+highway(?=\s|$)/ Hwy/gi;
    $value =~ s/\s+lane(?=\s|$)/ Ln/gi;
    $value =~ s/\s+parkway(?=\s|$)/ Pkwy/gi;
    $value =~ s/\s+place(?=\s|$)/ Pl/gi;
    $value =~ s/\s+road(?=\s|$)/ Rd/gi;
    $value =~ s/\s+street(?=\s|$)/ St/gi;
    $value =~ s/\s+terrace(?=\s|$)/ Ter/gi;

    # Fix capitalization of abbreviations (common short form to USPS abbreviation)
    $value =~ s/\s+av(?=\s|$)/ Ave/gi;
    $value =~ s/\s+dr(?=\s|$)/ Dr/gi; # Redundant, but ensures consistency
    $value =~ s/\s+blvd(?=\s|$)/ Blvd/gi; # Redundant
    $value =~ s/\s+ct(?=\s|$)/ Ct/gi; # Redundant
    $value =~ s/\s+hwy(?=\s|$)/ Hwy/gi; # Redundant
    $value =~ s/\s+ln(?=\s|$)/ Ln/gi; # Redundant
    $value =~ s/\s+pkwy(?=\s|$)/ Pkwy/gi; # Redundant
    $value =~ s/\s+pl(?=\s|$)/ Pl/gi; # Redundant
    $value =~ s/\s+rd(?=\s|$)/ Rd/gi; # Redundant
    $value =~ s/\s+st(?=\s|$)/ St/gi; # Redundant
    $value =~ s/\s+ter(?=\s|$)/ Ter/gi; # Redundant

    # Apartments and Building abbreviations
    $value =~ s/\s+unit(?=\s|$)/ Unit/gi;
    $value =~ s/\s+apt(?=\s|$)/ Apt/gi;
    $value =~ s/\s+apartment(?=\s|$)/ Apt/gi;
    $value =~ s/\s+bldg(?=\s|$)/ Bldg/gi;
    $value =~ s/\s+building(?=\s|$)/ Bldg/gi;

    # Complex Street Corrections (order sensitive)
    $value =~ s/Ct Ave/Court Ave/gi; # e.g., "Court Ave" instead of "Ct Ave"
    $value =~ s/Ct St/Court St/gi;
    $value =~ s/Dr Pl(?=\s|$)/Drive Pl/gi;
    $value =~ s/Ln Ave/Lane Ave/gi;
    $value =~ s/Ln St/Lane St/gi;
    $value =~ s/Rd Loop(?=\s|$)/Road Loop/gi;
    $value =~ s/St Loop(?=\s|$)/Street Loop/gi;
    $value =~ s/St Dr(?=\s|$)/Street Dr/gi;
    $value =~ s/St Ct(?=\s|$)/Street Ct/gi;
    $value =~ s/Ter Ave(?=\s|$)/Terrace Ave/gi;
    $value =~ s/Ter Ct(?=\s|$)/Terrace Ct/gi;
    $value =~ s/Ter Dr(?=\s|$)/Terrace Dr/gi;
    $value =~ s/Ter Trails(?=\s|$)/Terrace Trails/gi;
    $value =~ s/Ter View(?=\s|$)/Terrace View/gi;
    $value =~ s/Par 4th Dr$/Par 4 Dr/gi; # Specific fix
    $value =~ s/Pkwy Ct$/Parkway Ct/gi;

    # Fix numbered street names: Converts "1 St" to "1st St", "11 Ave" to "11th Ave", etc.
    # Note: Handles 0th, 1st, 2nd, 3rd explicitly, then uses 11th, 12th, 13th, otherwise "th"
    # This might need refinement for full English ordinal rules if strict adherence is needed.
    # This set of regexes needs careful ordering to avoid unintended double-conversions.
    # Group the street types for efficiency.
    my $street_types_re = qr/(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Pkwy)/;

    $value =~ s/(?<=\s)11\s($street_types_re)(?=\s|$)/11th $1/i;
    $value =~ s/(?<=\s)12\s($street_types_re)(?=\s|$)/12th $1/i;
    $value =~ s/(?<=\s)13\s($street_types_re)(?=\s|$)/13th $1/i;

    $value =~ s/(?<=\s)0\s($street_types_re)(?=\s|$)/0th $1/i; # Rarely used, but included
    $value =~ s/(?<=\s)1\s($street_types_re)(?=\s|$)/1st $1/i;
    $value =~ s/(?<=\s)2\s($street_types_re)(?=\s|$)/2nd $1/i;
    $value =~ s/(?<=\s)3\s($street_types_re)(?=\s|$)/3rd $1/i;
    $value =~ s/(?<=\s)4\s($street_types_re)(?=\s|$)/4th $1/i;
    $value =~ s/(?<=\s)5\s($street_types_re)(?=\s|$)/5th $1/i;
    $value =~ s/(?<=\s)6\s($street_types_re)(?=\s|$)/6th $1/i;
    $value =~ s/(?<=\s)7\s($street_types_re)(?=\s|$)/7th $1/i;
    $value =~ s/(?<=\s)8\s($street_types_re)(?=\s|$)/8th $1/i;
    $value =~ s/(?<=\s)9\s($street_types_re)(?=\s|$)/9th $1/i;

    # Oddments (e.g., HTML/XML-like entities)
    $value =~ s/<lf>/<LF>/gi; # Assuming <LF> is desired, otherwise remove.

    return $value;
}

=head2 format_city($value)

Formats a city name string.
This includes:
=over 4

=item * Trimming leading/trailing whitespace.
=item * Removing unwanted characters (keeping only letters, hyphens, apostrophes).
=item * Applying title capitalization to each word.
=item * Correcting common city name misspellings or variations.

=back

=head3 Parameters

=over 4

=item $value (string) - The raw city name string to format.

=back

=head3 Returns

The formatted city name string. Returns an empty string if the input is undefined.

=cut
sub format_city {
    my $value = shift;

    return '' unless defined $value;

    # Trim leading and trailing spaces
    $value =~ s/^\s+|\s+$//g;

    # Get rid of unwanted characters (keep letters, hyphens, apostrophes)
    $value =~ s/[^A-Za-z\-' ]//g;

    # Capitalization: Convert to lowercase, then capitalize the first letter of each word.
    my @words = split /\s+/, $value;
    foreach my $word_ref (@words) { # Use direct reference for efficiency
        $word_ref = ucfirst(lc($word_ref));
    }
    $value = join ' ', @words;

    # Fix common misspellings (case-insensitive)
    $value =~ s/Battleground/Battle Ground/i;
    $value =~ s/Fariview/Fairview/i;
    $value =~ s/Happyvalley/Happy Valley/i;
    $value =~ s/Milwakie/Milwaukie/i;
    $value =~ s/Potland/Portland/i;
    $value =~ s/Porltand/Portland/i;
    $value =~ s/Porland/Portland/i;
    $value =~ s/Praire/Prairie/i;
    $value =~ s/Troutdlae/Troutdale/i;
    $value =~ s/Woodvillage/Wood Village/i;
    $value =~ s/Mcminnville/McMinnville/i; # Retains camel case
    $value =~ s/Mcminville/McMinnville/i; # Retains camel case
    $value =~ s/Kailua-Kona/Kailua-Kona/i; # Ensures consistent hyphenation and casing
    $value =~ s/Coeur d'Alene/Coeur d'Alene/i; # Ensures consistent casing
    $value =~ s/Milton-Freewater/Milton-Freewater/i; # Ensures consistent hyphenation and casing
    $value =~ s/Gresha/Gresham/i;
    $value =~ s/Greshamm/Gresham/i;
    $value =~ s/Lakeoswego/Lake Oswego/i;
    $value =~ s/Lake Oswego/Lake Oswego/i; # Redundant, but ensures consistency
    $value =~ s/St Helen(s{0,1})/Saint Helens/i; # Handles both "St Helen" and "St Helens"
    $value =~ s/Hillsburo/Hillsboro/i;

    return $value;
}

=head2 format_state($value)

Formats a state name string into its 2-letter USPS abbreviation.
It supports full state names, common abbreviations, and defaults to 'OR' if
the state cannot be identified.

=head3 Parameters

=over 4

=item $value (string) - The raw state name string to format.

=back

=head3 Returns

The 2-letter USPS state abbreviation (e.g., 'OR', 'CA'). Defaults to 'OR'
if the input is not recognized or is undefined.

=cut
sub format_state {
    my $value = shift;

    # Return default 'OR' if input is not defined
    return 'OR' unless defined $value;

    # Map of common state names/abbreviations to USPS 2-letter codes
    # Use a 'my' hash for lexical scope, loaded once.
    my %states_map = (
        'ALABAMA' => 'AL', 'ALA' => 'AL', 'AL' => 'AL',
        'ARIZONA' => 'AZ', 'ARIZ' => 'AZ', 'AZ' => 'AZ',
        'ARKANSAS' => 'AR', 'ARK' => 'AR', 'AR' => 'AR',
        'CALIFORNIA' => 'CA', 'CALIF' => 'CA', 'CA' => 'CA',
        'COLORADO' => 'CO', 'COLO' => 'CO', 'CO' => 'CO',
        'CONNECTICUT' => 'CT', 'CONN' => 'CT', 'CT' => 'CT',
        'DELAWARE' => 'DE', 'DEL' => 'DE', 'DE' => 'DE',
        'DISTRICTOFCOLUMBIA' => 'DC', 'DC' => 'DC',
        'FLORIDA' => 'FL', 'FLA' => 'FL', 'FL' => 'FL',
        'GEORGIA' => 'GA', 'GA' => 'GA',
        'ILLINOIS' => 'IL', 'ILL' => 'IL', 'IL' => 'IL',
        'INDIANA' => 'IN', 'IND' => 'IN', 'IN' => 'IN',
        'KANSAS' => 'KS', 'KANS' => 'KS', 'KS' => 'KS',
        'KENTUCKY' => 'KY', 'KY' => 'KY',
        'MAINE' => 'ME', 'ME' => 'ME',
        'MARYLAND' => 'MD', 'MD' => 'MD',
        'MASSACHUSETTS' => 'MA', 'MASS' => 'MA', 'MA' => 'MA',
        'MICHIGAN' => 'MI', 'MICH' => 'MI', 'MI' => 'MI',
        'MINNESOTA' => 'MN', 'MINN' => 'MN', 'MN' => 'MN',
        'MISSISSIPPI' => 'MS', 'MISS' => 'MS', 'MS' => 'MS',
        'MISSOURI' => 'MO', 'MO' => 'MO',
        'MONTANA' => 'MT', 'MONT' => 'MT', 'MT' => 'MT',
        'NEBRASKA' => 'NE', 'NEBR' => 'NE', 'NE' => 'NE',
        'NEVADA' => 'NV', 'NEV' => 'NV', 'NV' => 'NV',
        'NEWHAMPSHIRE' => 'NH', 'NH' => 'NH',
        'NEWJERSEY' => 'NJ', 'NJ' => 'NJ',
        'NEWMEXICO' => 'NM', 'NMEX' => 'NM', 'NM' => 'NM',
        'NEWYORK' => 'NY', 'NY' => 'NY',
        'NORTHCAROLINA' => 'NC', 'NC' => 'NC',
        'OKLAHOMA' => 'OK', 'OKLA' => 'OK', 'OK' => 'OK',
        'OREGON' => 'OR', 'ORE' => 'OR', 'OR' => 'OR',
        'PENNSYLVANIA' => 'PA', 'PENN' => 'PA', 'PA' => 'PA',
        'RHODEISLAND' => 'RI', 'RI' => 'RI',
        'SOUTHCAROLINA' => 'SC', 'SC' => 'SC',
        'TENNESSEE' => 'TN', 'TENN' => 'TN', 'TN' => 'TN',
        'TEXAS' => 'TX', 'TEX' => 'TX', 'TX' => 'TX',
        'VERMONT' => 'VT', 'VT' => 'VT',
        'VIRGINIA' => 'VA', 'VA' => 'VA',
        'WASHINGTON' => 'WA', 'WASH' => 'WA', 'WA' => 'WA',
        'WESTVIRGINIA' => 'WV', 'WVA' => 'WV', 'WV' => 'WV',
        'WISCONSIN' => 'WI', 'WIS' => 'WI', 'WI' => 'WI',
        'WYOMING' => 'WY', 'WYO' => 'WY', 'WY' => 'WY',
    );

    # Convert input to uppercase for case-insensitive lookup
    $value = uc($value);
    # Remove all spaces and non-alphabetic characters to normalize for lookup
    $value =~ s/\s+//g;
    $value =~ s/[^A-Z]//g;

    # Check if the normalized value exists in the map
    if (exists $states_map{$value}) {
        return $states_map{$value};
    } else {
        # Default to 'OR' if not found
        if ($DEBUG_LEVEL >= 1) {
            warn "AddressFormat: Unknown state '$value'. Defaulting to 'OR'.\n";
        }
        return 'OR';
    }
}

# End of package. Returns a true value.
1;
