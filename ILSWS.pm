package ILSWS;

my $LEVEL = 1;

# Pragmas
use strict;
use warnings;

# Modules required
use LWP::UserAgent;
use HTTP::Request;
use XML::Hash::LX;
use YAML::Tiny;
use URI::Encode;
use JSON;
use Cwd;

# Define global constants
our $DEFAULT_TIMEOUT = 20;
our $DEFAULT_PATRON_SEARCH_COUNT = 1000;

our @PATRON_INCLUDE_FIELDS = (
  'profile',
  'birthDate',
  'library',
  'alternateID',
  'firstName',
  'middleName',
  'displayName',
  'lastName',
  'address1',
  'barcode',
  'category01',
  'category02',
  'category07'
);

# Define global variables
our $base_path = getcwd;
$base_path = $ENV{'ILSWS_BASE_PATH'} if $ENV{'ILSWS_BASE_PATH'};

our $error = '';
our $code = 0;

# Read configuration file
our $yaml = YAML::Tiny->read("$base_path/config.yaml");
our $base_URL = qq(https://$yaml->[0]->{'ilsws'}->{'hostname'}:$yaml->[0]->{'ilsws'}->{'port'}/$yaml->[0]->{'ilsws'}->{'webapp'});

###############################################################################
# Subroutines
###############################################################################
#
###############################################################################
# Routine for establishing a connection with ILSWS and logging in. Returns a
# token which is used in subsequent queries.

sub ILSWS_connect {

  # Define the URL for ILSWS
  my $action = 'rest/security/loginUser';
  my $params = "clientID=$yaml->[0]->{'ilsws'}->{'client_id'}&login=$yaml->[0]->{'ilsws'}->{'username'}&password=$yaml->[0]->{'ilsws'}->{'password'}";
  my $URL = "$base_URL/$action?$params";

  # Create user agent object
  my $timeout = defined $yaml->[0]->{'ilsws'}->{'timeout'} ? $yaml->[0]->{'ilsws'}->{'timeout'} : $DEFAULT_TIMEOUT;
  my $ua = LWP::UserAgent->new(
    timeout => $timeout,
    ssl_opts => { verify_hostname => 1 },
    protocols_allowed => ['https'],
    protocals_forbidden => ['http']
    );
  
  # Post the request
  my $res = $ua->get($URL);

  my $token = '';
  if ( $res->is_success ) {

    # Load response XML into hash
    my $res_hash = xml2hash $res->decoded_content;

    # Check if we got a token
    if ( defined $res_hash->{'LoginUserResponse'}->{'sessionToken'} ) {
      $token = $res_hash->{'LoginUserResponse'}->{'sessionToken'};
    } else {
      $error = $res->decoded_content;
    }

  } else {
    $error = $res->status_line;
  }

  return $token;
}

###############################################################################
# Search for patron by any valid single field

sub patron_search {
  my $token = shift;
  my $index = shift;
  my $value = shift; 
  my $count = shift;
 
  # Number of results to return
  $count = defined $count ? $count : $DEFAULT_PATRON_SEARCH_COUNT;

  # Fields to return in result
  my $include_fields = join(',', @PATRON_INCLUDE_FIELDS);

  # Define query parameters JSON
  my %params = (
    'q' => "$index:$value",
    'rw' => 1,
    'ct' => $count,
    'includeFields' => $include_fields
    );

  return &send_get("$base_URL/user/patron/search", $token, \%params);
}

###############################################################################
# Search by alternate ID number

sub patron_alt_id_search {
  my $token = shift;
  my $value = shift;
  my $count = shift;

  return &patron_search($token, 'ALT_ID', $value, $count);
}

###############################################################################
# Search by barcode number

sub patron_barcode_search {
  my $token = shift;
  my $value = shift; 
  my $count = shift;
 
  return &patron_search($token, 'ID', $value, $count);
}

###############################################################################
# Create a new patron record

sub patron_create {
  my $token = shift;
  my $json = shift;

  my $res = &send_post("$base_URL/user/patron", $token, $json);

  if ( $code == 404 ) {
    $error = "404: Invalid access point (resource)";
  }

  return $res;
}

###############################################################################
# Update existing patron record

sub patron_update {
  my $token = shift;
  my $json = shift;
  my $key = shift;

  my $res = '';
  if ( $key =~ /^\d+$/ ) {
    $res = &send_post("$base_URL/user/patron/key/$key", $token, $json, 'PUT');
  } else {
    $error = "Missing key!";
  }

  return $res;
}

###############################################################################
# Update the patron lastActivityDate

sub activity_update {
  my $token = shift;
  my $json = shift;

  return &send_post("$base_URL/user/patron/updateActivityDate", $token, $json, 'POST');
}

###############################################################################
# Create a standard GET request object. Used by most searches.

sub send_get {
  my $URL = shift;
  my $token = shift;
  my $params = shift;

  # Encode the query parameters, as they will be sent in the URL
  if ( $params ) {
    my $encoder = URI::Encode->new();
    $URL .= "?";
    foreach my $key ('q','rw','ct','includeFields') {
      if ( $params->{$key} ) {
        $URL .= "$key=" . $encoder->encode($params->{$key}) . '&';
      }
    }
    chop $URL;
  }

  # Define the request headers
  my $req = HTTP::Request->new('GET', $URL);
  $req->header( 'Content-Type' => 'application/json' );
  $req->header( 'Accept' => 'application/json' );
  $req->header( 'SD-Originating-App-Id' => $yaml->[0]->{'ilsws'}->{'app_id'} );
  $req->header( 'x-sirs-clientID' => $yaml->[0]->{'ilsws'}->{'client_id'} );
  $req->header( 'x-sirs-sessionToken' => $token );

  # Define the user agent instance
  my $ua = LWP::UserAgent->new(
    timeout => $yaml->[0]->{'ilsws'}->{'timeout'},
    ssl_opts => { verify_hostname => 1 },
    protocols_allowed => ['https'],
    protocals_forbidden => ['http']
    );

  my $res = $ua->request($req);

  # Set the response code so other functions can check it as needed
  $code = $res->code;

  # Prepare to deal with JSON
  my $json = JSON->new->allow_nonref;

  # If we were successful, return the content in a perl hash. If we were not
  # successful return nothing and set the global error variable.
  my $data = '';
  if ( $res->is_success ) {
    $data = $json->decode($res->decoded_content);
  } else {
    $error = $res->decoded_content;
  }

  return $data;
}

###############################################################################
# Create a standard POST request object. Used by most updates and creates.

sub send_post {
  my $URL = shift;
  my $token = shift;
  my $query_json = shift;
  my $query_type = shift;

  if ( ! $query_type ) {
    $query_type = 'POST';
  }

  # Define the request headers
  my $req = HTTP::Request->new($query_type, $URL);
  $req->header( 'Content-Type' => 'application/json' );
  $req->header( 'Accept' => 'application/json' );
  $req->header( 'SD-Originating-App-Id' => $yaml->[0]->{'ilsws'}->{'app_id'} );
  $req->header( 'SD-Preferred-Role' => 'STAFF' );
  $req->header( 'SD-Prompt-Return' => "USER_PRIVILEGE_OVRCD/$yaml->[0]->{'ilsws'}->{'user_privilege_override'}" );
  $req->header( 'x-sirs-clientID' => $yaml->[0]->{'ilsws'}->{'client_id'} );
  $req->header( 'x-sirs-sessionToken' => $token );
  $req->content( $query_json );

  # print $req->as_string;

  # Define the user agent instance
  my $ua = LWP::UserAgent->new(
    timeout => $yaml->[0]->{'ilsws'}->{'timeout'},
    ssl_opts => { verify_hostname => 1 },
    protocols_allowed => ['https'],
    protocals_forbidden => ['http'],
  );

  my $res = $ua->request($req);

  # Prepare to deal with JSON
  my $json = JSON->new->allow_nonref;

  # Set the response code so other functions can check it as needed
  $code = $res->code;

  # If we were successful, return the content in a perl hash. If we were not
  # successful return nothing and set the global error variable.
  my $data = '';
  if ( $res->is_success ) {
    $data = $json->decode($res->decoded_content);
  } else {
    $error = $res->decoded_content;
  }

  return $data;
}

###############################################################################
1;

