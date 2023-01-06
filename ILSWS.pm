package ILSWS;

my $LEVEL = 1;

# Pragmas
use strict;
use warnings;

use Exporter;
our @ISA= qw( Exporter );
our @EXPORT_OK = qw(ILSWS_connect patron_authenticate patron_describe patron_search patron_alt_id_search patron_barcode_search patron_create patron_update activity_update send_get send_post);
our @EXPORT = qw(import);

# Modules required
use LWP::UserAgent;
use HTTP::Request;
use XML::Simple qw(:strict);
use YAML::Tiny;
use URI;
use JSON;
use Cwd;

# Define global constants
our $BASE_PATH;
our $DEFAULT_TIMEOUT = 20;
our $DEFAULT_PATRON_SEARCH_ROW = 1;
our $DEFAULT_PATRON_SEARCH_COUNT = 1000;
our $DEFAULT_PATRON_SEARCH_BOOLEAN = 'AND';

our @PATRON_INCLUDE_FIELDS = (
  'profile',
  'birthDate',
  'library',
  'lastActivityDate',
  'alternateID',
  'firstName',
  'middleName',
  'displayName',
  'lastName',
  'address1',
  'barcode',
  'category01',
  'category02',
  'category07',
  'category11'
);

# Define global variables
our $error = '';
our $code = 0;
our $yaml = '';
our $base_URL = '';

###############################################################################
# Subroutines
###############################################################################
# Get the base_path from a parameter

sub import {
  my ($package, $path) = @_;
  $BASE_PATH = $path;
  
  if ( ! $BASE_PATH ) {  
    $BASE_PATH = $ENV{'ILSWS_BASE_PATH'} if $ENV{'ILSWS_BASE_PATH'};
  }
  if ( ! $BASE_PATH ) {
    $BASE_PATH = getcwd;
  }
  
  # Read configuration file
  $yaml = YAML::Tiny->read("$BASE_PATH/config.yaml");
  $base_URL = qq(https://$yaml->[0]->{'ilsws'}->{'hostname'}:$yaml->[0]->{'ilsws'}->{'port'}/$yaml->[0]->{'ilsws'}->{'webapp'});
}
 
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
    protocals_forbidden => ['http'],
    protocols_allowed => ['https']
    );
  
  # Post the request
  my $res = $ua->get($URL);

  my $token = '';
  if ( $res->is_success ) {

    # Load response XML into hash
    my $res_hash = XMLin($res->decoded_content, ForceArray => 1, KeyAttr => 'LoginUserResponse');

    # Check if we got a token
    if ( defined $res_hash->{'sessionToken'} ) {
      $token = $res_hash->{'sessionToken'};
    } else {
      $error = $res->decoded_content;
    }

  } else {
    $error = $res->status_line;
  }

  return $token;
}

###############################################################################
# Authenticate a patron via ID (Barcode) and pin

sub patron_authenticate {
  my $token = shift;
  my $id = shift;
  my $pin = shift;

  my $json = qq|{ "barcode": "$id", "password": "$pin" }|;

  return &send_post("$base_URL/user/patron/authenticate", $token, $json, 'POST');
}

###############################################################################
# Describe the patron resource

sub patron_describe {
  my $token = shift;
  
  return &send_get("$base_URL/user/patron/describe", $token);
}

###############################################################################
# Search for patron by any valid single field

sub patron_search {
  my $token = shift;
  my $index = shift;
  my $value = shift;
  my $options = shift;

  # Number of results to return
  $options->{'ct'} = $DEFAULT_PATRON_SEARCH_COUNT unless $options->{'ct'};

  # Row to start on (so you can page through results)
  $options->{'rw'} = $DEFAULT_PATRON_SEARCH_ROW unless $options->{'rw'};

  # Boolean AND or OR to use with multiple search terms
  $options->{'j'} = $DEFAULT_PATRON_SEARCH_BOOLEAN unless $options->{'j'};

  # Fields to return in result
  $options->{'includeFields'} = join(',', @PATRON_INCLUDE_FIELDS) unless $options->{'includeFields'};

  # Define query parameters JSON
  my %params = (
    'q' => "$index:$value",
    'rw' => $options->{'rw'},
    'ct' => $options->{'ct'},
    'j' => $options->{'j'},
    'includeFields' => $options->{'includeFields'}
    );

  return &send_get("$base_URL/user/patron/search", $token, \%params);
}

###############################################################################
# Search by alternate ID number

sub patron_alt_id_search {
  my $token = shift;
  my $value = shift;
  my $options = shift;

  return &patron_search($token, 'ALT_ID', $value, $options);
}

###############################################################################
# Search by barcode number

sub patron_barcode_search {
  my $token = shift;
  my $value = shift; 
  my $options = shift;
 
  return &patron_search($token, 'ID', $value, $options);
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
    # my $encoder = URI::Encode->new();
    $URL .= "?";
    foreach my $key ('q','rw','ct','j','includeFields') {
      if ( $params->{$key} ) {
        $URL .= "$key=" . URI->new($params->{$key}, 'HTTP') . '&';
      }
    }
    chop $URL;
    $URL =~ s/(.*)\#(.*)/$1%23$2/;
  }

  # Set $error to the URL being submitted so that it can be accessed
  # in debug mode
  $error = $URL;

  # Define a random request tracker
  my $req_num = 1 + int rand(1000000000);

  # Define the request headers
  my $req = HTTP::Request->new('GET', $URL);
  $req->header( 'Content-Type' => 'application/json' );
  $req->header( 'Accept' => 'application/json' );
  $req->header( 'SD-Originating-App-Id' => $yaml->[0]->{'ilsws'}->{'app_id'} );
  $req->header( 'SD-Request-Tracker' => $req_num );
  $req->header( 'x-sirs-clientID' => $yaml->[0]->{'ilsws'}->{'client_id'} );
  $req->header( 'x-sirs-sessionToken' => $token );

  # Define the user agent instance
  my $ua = LWP::UserAgent->new(
    timeout => $yaml->[0]->{'ilsws'}->{'timeout'},
    ssl_opts => { verify_hostname => 1 },
    protocols_allowed => ['https'],
    protocals_forbidden => ['http'],
  );

  # Submit the request
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

  # Define a random request tracker
  my $req_num = 1 + int rand(1000000000);

  # Define the request headers
  my $req = HTTP::Request->new($query_type, $URL);
  $req->header( 'Content-Type' => 'application/json' );
  $req->header( 'Accept' => 'application/json' );
  $req->header( 'SD-Originating-App-Id' => $yaml->[0]->{'ilsws'}->{'app_id'} );
  $req->header( 'SD-Response-Tracker' => $req_num );
  $req->header( 'SD-Preferred-Role' => 'STAFF' );
  $req->header( 'SD-Prompt-Return' => "USER_PRIVILEGE_OVRCD/$yaml->[0]->{'ilsws'}->{'user_privilege_override'}" );
  $req->header( 'x-sirs-clientID' => $yaml->[0]->{'ilsws'}->{'client_id'} );
  $req->header( 'x-sirs-sessionToken' => $token );
  $req->content( $query_json );

  # Define the user agent instance
  my $ua = LWP::UserAgent->new(
    timeout => $yaml->[0]->{'ilsws'}->{'timeout'},
    ssl_opts => { verify_hostname => 1 },
    protocols_allowed => ['https'],
    protocals_forbidden => ['http'],
  );

  # Submit the request
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
