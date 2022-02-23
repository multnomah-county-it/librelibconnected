package AddressFormat;

# Package with routines for formatting address elements to conform with
# USPS guidelines

my $LEVEL = 1;

sub format_street {
  my $value = shift;

  # Trim leading or trailing spaces
  $value =~ s/^\s+//;
  $value =~ s/\s+$//;

  # Remove periods and commas
  $value =~ s/\.//g;
  $value =~ s/\,//g;

  # Space # signs per USPS
  $value =~ s/\s+\#(?!\s|$)/ # /g;

  # Title capitalization for all words over two characters long
  my @words = split /\s+/, $value;
  foreach my $i (0 .. $#words) {

    # If the word has more than one uppercase, assume it's an acronym.
    if ($words[$i] !~ /[A-Z]+/ || length($words[$i]) > 4) {
      $words[$i] = lc($words[$i]);
      $words[$i] = ucfirst($words[$i]);
    }
  }
  $value = join ' ', @words;

  # Correct street names
  $value =~ s/ Cesar Chavez/ Cesar E Chavez/gi;
  $value =~ s/ Martin Luther King Jr/ML King/gi;
  $value =~ s/ MLK Jr/ ML King/gi;
  $value =~ s/ MLK/ ML King/gi;
  $value =~ s/ BRdway(?=\s|$)/ Broadway/gi;

  # Special cases
  $value =~ s#c/o(?=\s)#C/O#gi;
  $value =~ s/^po box(?=\s+)/PO Box/gi;
  $value =~ s/\s+bkvd(?=\s|$)/ Blvd/gi;

  # Compass regions
  $value =~ s/\s+n(?=\s|$)/ N/gi;
  $value =~ s/\s+ne(?=\s|$)/ NE/gi;
  $value =~ s/\s+nw(?=\s|$)/ NW/gi;
  $value =~ s/\s+s(?=\s|$)/ S/gi;
  $value =~ s/\s+se(?=\s|$)/ SE/gi;
  $value =~ s/\s+sw(?=\s|$)/ SW/gi;

  # Abbreviate street types
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

  # Fix capitalization of abbreviations
  $value =~ s/\s+av(?=\s|$)/ Ave/gi;
  $value =~ s/\s+dr(?=\s|$)/ Dr/gi;
  $value =~ s/\s+blvd(?=\s|$)/ Blvd/gi;
  $value =~ s/\s+ct(?=\s|$)/ Ct/gi;
  $value =~ s/\s+dr(?=\s|$)/ Dr/gi;
  $value =~ s/\s+hwy(?=\s|$)/ Hwy/gi;
  $value =~ s/\s+ln(?=\s|$)/ Ln/gi;
  $value =~ s/\s+pkwy(?=\s|$)/ Pkwy/gi;
  $value =~ s/\s+pl(?=\s|$)/ Pl/gi;
  $value =~ s/\s+rd(?=\s|$)/ Rd/gi;
  $value =~ s/\s+st(?=\s|$)/ St/gi;
  $value =~ s/\s+ter(?=\s|$)/ Ter/gi;

  # Apartments
  $value =~ s/\s+unit(?=\s|$)/ Unit/gi;
  $value =~ s/\s+apt(?=\s|$)/ Apt/gi;
  $value =~ s/\s+apartment(?=\s|$)/ Apt/gi;
  $value =~ s/\s+bldg(?=\s|$)/ Bldg/gi;
  $value =~ s/\s+building(?=\s|$)/ Bldg/gi;

  # Street Corrections
  $value =~ s/ Ct Ave/ Court Ave/g;
  $value =~ s/ Ct St/ Court St/g;
  $value =~ s/ Dr Pl(?=\s|$)/ Drive Pl/i;
  $value =~ s/ Ln Ave/ Lane Ave/g;
  $value =~ s/ Ln St/ Lane St/g;
  $value =~ s/ Rd Loop(?=\s|$)/ Road Loop/i;
  $value =~ s/ St Loop(?=\s|$)/ Street Loop/i;
  $value =~ s/ St Dr(?=\s|$)/ Street Dr/i;
  $value =~ s/ Ter Ave(?=\s|$)/ Terrace Ave/i;
  $value =~ s/ Ter Ct(?=\s|$)/ Terrace Ct/i;
  $value =~ s/ Ter Dr(?=\s|$)/ Terrace Dr/i;
  $value =~ s/ Ter Trails(?=\s|$)/ Terrace Trails/i;
  $value =~ s/ Ter View(?=\s|$)/ Terrace View/i;
  $value =~ s/ Par 4th Dr$/ Par 4 Dr/i;

  # Fix numbered street names
  $value =~ s/(11\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/11th $2/i;
  $value =~ s/(12\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/12th $2/i;
  $value =~ s/(13\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/13th $2/i;

  $value =~ s/(0\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/0th $2/i;
  $value =~ s/(1\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/1st $2/i;
  $value =~ s/(2\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/2nd $2/i;
  $value =~ s/(3\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/3rd $2/i;
  $value =~ s/(4\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/4th $2/i;
  $value =~ s/(5\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/5th $2/i;
  $value =~ s/(6\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/6th $2/i;
  $value =~ s/(7\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/7th $2/i;
  $value =~ s/(8\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/8th $2/i;
  $value =~ s/(9\s)(St|Ave|Rd|Ln|Blvd|Ct|Pl|Dr|Hwy|Pkwy)(?=\s|$)/9th $2/i;

  # Oddments
  $value =~ s/<lf>/<LF>/gi;

  return $value;
}

###############################################################################
# Routine for formatting cities

sub format_city {
  my $value = shift;

  # Trim leading and trailing spaces
  $value =~ s/^\s+//;
  $value =~ s/\s+$//;

  # Get rid of unwanted characters
  $value =~ s/[^\-'A-Za-z]+//g;

  # Capitalization
  @words = split /\s+/, $value;
  foreach my $i (0 .. $#words) {
    $words[$i] = lc($words[$i]);
    $words[$i] = ucfirst($words[$i]);
  }
  $value = join ' ', @words;

  # Fix common mispellings
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
  $value =~ s/Mcminnville/McMinnville/i;
  $value =~ s/Mcminville/McMinnville/i;
  $value =~ s/Kailua-Kona/Kailua-Kona/i;
  $value =~ s/Coeur d'Alene/Coeur d'Alene/i;
  $value =~ s/Milton-Freewater/Milton-Freewater/i;
  $value =~ s/Gresha/Gresham/i;
  $value =~ s/Greshamm/Gresham/i;
  $value =~ s/Lake Oswego/Lake Oswego/i;
  $value =~ s/St Helen(s{0,1})/Saint Helens/i;
  $value =~ s/Hillsburo/Hillsboro/i;

  return $value;
}

###############################################################################
# Routine for formatting states

sub format_state {
  my $value = shift;

  my %states = (
        'ALABAMA' => 'AL',
    'ALA' => 'AL',
    'AL' => 'AL',
    'ARIZONA' => 'AZ',
    'ARIZ' => 'AZ',
    'AZ' => 'AZ',
    'ARKANSAS' => 'AR',
    'ARK' => 'AR',
    'AR' => 'AR',
    'CALIFORNIA' => 'CA',
    'CALIF' => 'CA',
    'CA' => 'CA',
    'COLORADO' => 'CO',
    'COLO' => 'CO',
    'CO' => 'CO',
    'CONNECTICUT' => 'CT',
    'CONN' => 'CT',
    'CT' => 'CT',
    'DELAWARE' => 'DE',
    'DEL' => 'DE',
    'DE' => 'DE',
    'DISTRICTOFCOLUMBIA' => 'DC',
    'DC' => 'DC',
    'FLORIDA' => 'FL',
    'FLA' => 'FL',
    'FL' => 'FL',
    'GEORGIA' => 'GA',
    'GA' => 'GA',
    'ILLINOIS' => 'IL',
    'ILL' => 'IL',
    'IL' => 'IL',
    'INDIANA' => 'IN',
    'IND' => 'IN',
    'IN' => 'IN',
    'KANSAS' => 'KS',
    'KANS' => 'KS',
    'KS' => 'KS',
    'KENTUCKY' => 'KY',
    'KY' => 'KY',
    'MAINE' => 'ME',
    'ME' => 'ME',
    'MARYLAND' => 'MD',
    'MD' => 'MD',
    'MASSACHUSETTS' => 'MA',
    'MASS' => 'MA',
    'MA' => 'MA',
    'MICHIGAN' => 'MI',
    'MICH' => 'MI',
    'MI' => 'MI',
    'MINNESOTA' => 'MN',
    'MINN' => 'MN',
    'MN' => 'MN',
    'MISSISSIPPI' => 'MS',
    'MISS' => 'MS',
    'MS' => 'MS',
    'MISSOURI' => 'MO',
    'MO' => 'MO',
    'MONTANA' => 'MT',
    'MONT' => 'MT',
    'MT' => 'MT',
    'NEBRASKA' => 'NE',
    'NEBR' => 'NE',
    'NE' => 'NE',
    'NEVADA' => 'NV',
    'NEV' => 'NV',
    'NV' => 'NV',
    'NEWHAMPSHIRE' => 'NH',
    'NH' => 'NH',
    'NEWJERSEY' => 'NJ',
    'NJ' => 'NJ',
    'NEWMEXICO' => 'NM',
    'NMEX' => 'NM',
    'NM' => 'NM',
    'NEWYORK' => 'NY',
    'NY' => 'NY',
    'NORTHCAROLINA' => 'NC',
    'NC' => 'NC',
    'OKLAHOMA' => 'OK',
    'OKLA' => 'OK',
    'OK' => 'OK',
    'OREGON' => 'OR',
    'ORE' => 'OR',
    'OR' => 'OR',
    'PENNSYLVANIA' => 'PA',
    'PENN' => 'PA',
    'PA' => 'PA',
    'RHODEISLAND' => 'RI',
    'RI' => 'RI',
    'SOUTHCAROLINA' => 'SC',
    'SC' => 'SC',
    'TENNESSEE' => 'TN',
    'TENN' => 'TN',
    'TN' => 'TN',
    'TEXAS' => 'TX',
    'TEX' => 'TX',
    'TX' => 'TX',
    'VERMONT' => 'VT',
    'VT' => 'VT',
    'VIRGINIA' => 'VA',
    'VA' => 'VA',
    'WASHINGTON' => 'WA',
    'WASH' => 'WA',
    'WA' => 'WA',
    'WESTVIRGINIA' => 'WV',
    'WVA' => 'WV',
    'WV' => 'WV',
    'WISCONSIN' => 'WI',
    'WIS' => 'WI',
    'WI' => 'WI',
    'WYOMING' => 'WY',
    'WYO' => 'WY',
    'WY' => 'WY',
  );

  # Convert value to state key
  $value = uc($value);
  $abbrev =~ s/\s+//g;
  $abbrev =~ s/[^A-Z]+//g;

  # Check if state key exists and get code or set to OR
  if ( $states{$value} ) {
    $value = $states{$value};
  } else {
    $value = 'OR';
  }

  return $value;
}

###############################################################################

1;
