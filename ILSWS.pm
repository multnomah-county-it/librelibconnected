package ILSWS;

# This module provides an interface for interacting with the ILS Web Services (ILSWS) API.
# It handles authentication, various patron search and update operations, and manages
# API requests and responses.

# Pragmas
use strict;
use warnings;
use utf8; # For handling Unicode characters if present in data

# Standard Exporter setup for Perl modules
use Exporter qw(import);
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
    ILSWS_connect
    patron_authenticate
    patron_describe
    patron_search
    patron_alt_id_search
    patron_barcode_search
    patron_create
    patron_update
    patron_update_activeid
    activity_update
    send_get
    send_post
);
# 'import' is already handled by Exporter qw(import) and doesn't need to be in @EXPORT.
# Note: The 'import' function in this module is a custom subroutine (see line 76) used for configuration loading,
# not Exporter's import. It is not intended to be exported, so it is not included in @EXPORT or @EXPORT_OK.

# Modules required
use LWP::UserAgent;
use HTTP::Request;
use XML::Simple; # Note: XML::Simple is often discouraged for complex XML due to its simplicity, but for specific API responses, it might be acceptable.
use YAML::Tiny;
use URI; # For URL manipulation and encoding
use JSON;
use Cwd qw(getcwd); # For getting current working directory
use Data::Dumper; # For debugging output

# --- Module-level Constants ---
use constant {
    MODULE_DEBUG_LEVEL            => 1,     # Internal debug level for this module (e.g., 0=off, 1=basic, 2=verbose)
    DEFAULT_TIMEOUT               => 20,    # Default timeout for HTTP requests in seconds
    DEFAULT_PATRON_SEARCH_ROW     => 1,     # Default starting row for patron search results
    DEFAULT_PATRON_SEARCH_COUNT   => 1000,  # Default maximum number of results for patron search
    DEFAULT_PATRON_SEARCH_BOOLEAN => 'AND', # Default boolean operator for multi-term searches
};

# Fields to include by default in patron search results
use constant PATRON_INCLUDE_FIELDS => [
    'profile', 'birthDate', 'library', 'lastActivityDate', 'alternateID',
    'firstName', 'middleName', 'displayName', 'lastName', 'address1',
    'barcode', 'category01', 'category02', 'category07', 'category11'
];

# --- Module-level Global Variables ---
# These are 'our' as they represent module-wide state (config, last error).
# While global state is generally discouraged, for a simple API wrapper module,
# this pattern is common for error reporting and configuration.
our $error        = ''; # Stores the last error message from an API call
our $code         = 0;  # Stores the last HTTP response code from an API call
our $yaml_config  = {}; # Stores the parsed YAML configuration
our $base_URL     = ''; # Stores the base URL for ILSWS API calls
our $base_path    = ''; # Stores the local path to the application

###############################################################################
# Subroutines
###############################################################################

# import: This subroutine is called automatically when the module is 'use'd.
# It sets up the base path and loads the configuration from config.yaml.
# It prioritizes the path passed as an argument, then an environment variable,
# then the current working directory.
sub import {
    my ($package, $path) = @_;

    my $effective_base_path;

    if (defined $path && length $path > 0) {
        $effective_base_path = $path;
    } elsif (defined $ENV{'ILSWS_BASE_PATH'} && length $ENV{'ILSWS_BASE_PATH'} > 0) {
        $effective_base_path = $ENV{'ILSWS_BASE_PATH'};
    } else {
        $effective_base_path = getcwd();
    }

    # Validate that the determined base path exists and is a directory
    unless (defined $effective_base_path && -d $effective_base_path) {
        die "ILSWS ERROR: Base path '$effective_base_path' is not a valid directory.\n";
    }

    # Store the determined base path globally for other functions to use
    $base_path = $effective_base_path;

    my $config_file = "$base_path/config.yaml";

    # Validate configuration file existence and readability
    unless (-f $config_file && -r $config_file) {
        die "ILSWS ERROR: Configuration file '$config_file' not found or not readable.\n";
    }

    # Read configuration file using YAML::Tiny
    eval {
        $yaml_config = YAML::Tiny->read($config_file);
    };
    if ($@) {
        die "ILSWS ERROR: Failed to read YAML configuration from '$config_file': $@\n";
    }

    # Validate essential configuration parameters
    unless (defined $yaml_config && ref $yaml_config->[0] eq 'HASH') {
        die "ILSWS ERROR: Invalid YAML configuration structure in '$config_file'. Expected array of hashes.\n";
    }
    my $ilsws_section = $yaml_config->[0]->{'ilsws'};
    unless (defined $ilsws_section && ref $ilsws_section eq 'HASH' &&
            defined $ilsws_section->{'hostname'} && defined $ilsws_section->{'port'} &&
            defined $ilsws_section->{'webapp'} && defined $ilsws_section->{'app_id'} &&
            defined $ilsws_section->{'client_id'} && defined $ilsws_section->{'username'} &&
            defined $ilsws_section->{'password'}) {
        die "ILSWS ERROR: Missing essential 'ilsws' configuration parameters in '$config_file'.\n";
    }

    # Construct the base URL for API calls
    $base_URL = sprintf("https://%s:%s/%s",
        $ilsws_section->{'hostname'},
        $ilsws_section->{'port'},
        $ilsws_section->{'webapp'}
    );

    if (MODULE_DEBUG_LEVEL >= 1) {
        warn "ILSWS: Module initialized. Base URL: $base_URL\n";
    }
}

# ILSWS_connect: Establishes a connection with ILSWS and logs in.
# Returns a session token on success, or undef on failure, setting $error and $code.
sub ILSWS_connect {
    $error = ''; # Clear previous error
    $code  = 0;  # Clear previous code

    my $ilsws_conf = $yaml_config->[0]->{'ilsws'};

    # Define the URL for ILSWS login
    my $url = "$base_URL/user/staff/login";

    # Construct the JSON payload for login
    my $query_json = JSON->new->encode({
        barcode  => $ilsws_conf->{'username'},
        password => $ilsws_conf->{'password'},
    });

    # Generate a random request tracker ID
    my $req_num = 1 + int(rand(1_000_000_000)); # Use underscore for readability

    # Define the request headers
    my $req = HTTP::Request->new('POST', $url);
    $req->header('Content-Type'          => 'application/json');
    $req->header('Accept'                => 'application/json');
    $req->header('SD-Originating-App-Id' => $ilsws_conf->{'app_id'});
    $req->header('SD-Response-Tracker'   => $req_num);
    $req->header('x-sirs-clientId'       => $ilsws_conf->{'client_id'});
    $req->content($query_json);

    # Create LWP::UserAgent object with timeout and SSL options
    my $timeout = $ilsws_conf->{'timeout'} // DEFAULT_TIMEOUT;
    my $ua = LWP::UserAgent->new(
        timeout             => $timeout,
        ssl_opts            => { verify_hostname => 1 }, # Always verify SSL certificates
        protocols_allowed   => ['https'],
        protocols_forbidden => ['http'], # Enforce HTTPS
    );

    # Post the request and handle response
    my $res;
    eval {
        $res = $ua->request($req);
    };
    if ($@) {
        $error = "Exception during HTTP request for ILSWS_connect: $@";
        $code  = 0; # Indicate no HTTP response received
        return undef;
    }

    $code = $res->code; # Set the global response code

    my $token = undef;
    if ($res->is_success) {
        # Load response JSON into hash
        my $json_parser = JSON->new->allow_nonref;
        my $res_hash;
        eval {
            $res_hash = $json_parser->decode($res->decoded_content);
        };
        if ($@) {
            $error = "Failed to decode JSON response for ILSWS_connect: $@. Content: " . $res->decoded_content;
            return undef;
        }

        # Check if we got a session token
        if (defined $res_hash->{'sessionToken'}) {
            $token = $res_hash->{'sessionToken'};
        } else {
            $error = "No 'sessionToken' found in successful login response. Content: " . $res->decoded_content;
        }
    } else {
        $error = "ILSWS_connect failed: " . $res->status_line . " - " . $res->decoded_content;
    }

    return $token;
}

# patron_authenticate: Authenticates a patron via ID (Barcode) and PIN.
# Returns the response hash on success, or undef on failure.
sub patron_authenticate {
    my ($token, $id, $pin) = @_;

    unless (defined $token && defined $id && defined $pin) {
        $error = "Missing required parameters for patron_authenticate.";
        $code = 0;
        return undef;
    }

    my $json_payload = JSON->new->encode({
        barcode  => $id,
        password => $pin,
    });

    return send_post("$base_URL/user/patron/authenticate", $token, $json_payload, 'POST');
}

# patron_describe: Describes the patron resource.
# Returns the response hash on success, or undef on failure.
sub patron_describe {
    my ($token) = @_;

    unless (defined $token) {
        $error = "Missing required token for patron_describe.";
        $code = 0;
        return undef;
    }

    return send_get("$base_URL/user/patron/describe", $token);
}

# patron_search: Searches for a patron by any valid single field.
# Returns the response hash on success, or undef on failure.
sub patron_search {
    my ($token, $index, $value, $options_ref) = @_;

    unless (defined $token && defined $index && defined $value) {
        $error = "Missing required parameters for patron_search.";
        $code = 0;
        return undef;
    }

    # Ensure options is a hash reference, provide defaults if not provided
    my %options = defined $options_ref && ref $options_ref eq 'HASH' ? %{$options_ref} : ();

    $options{'ct'}          = $options{'ct'} // DEFAULT_PATRON_SEARCH_COUNT;
    $options{'rw'}          = $options{'rw'} // DEFAULT_PATRON_SEARCH_ROW;
    $options{'j'}           = $options{'j'}  // DEFAULT_PATRON_SEARCH_BOOLEAN;
    $options{'includeFields'} = $options{'includeFields'} // join(',', PATRON_INCLUDE_FIELDS);

    # Define query parameters hash
    my %params = (
        q             => "$index:$value",
        rw            => $options{'rw'},
        ct            => $options{'ct'},
        j             => $options{'j'},
        includeFields => $options{'includeFields'}
    );

    return send_get("$base_URL/user/patron/search", $token, \%params);
}

# patron_alt_id_search: Searches for a patron by alternate ID number.
# Returns the response hash on success, or undef on failure.
sub patron_alt_id_search {
    my ($token, $value, $options) = @_;
    return patron_search($token, 'ALT_ID', $value, $options);
}

# patron_barcode_search: Searches for a patron by barcode number (ID field).
# Returns the response hash on success, or undef on failure.
sub patron_barcode_search {
    my ($token, $value, $options) = @_;
    return patron_search($token, 'ID', $value, $options);
}

# patron_create: Creates a new patron record.
# Returns the response hash on success, or undef on failure.
sub patron_create {
    my ($token, $json_payload) = @_;

    unless (defined $token && defined $json_payload) {
        $error = "Missing required parameters for patron_create.";
        $code = 0;
        return undef;
    }

    my $res = send_post("$base_URL/user/patron", $token, $json_payload);

    # Specific error handling for 404, if required by API behavior
    if ($code == 404) {
        $error = "404: Invalid access point (resource) for patron_create.";
    }

    return $res;
}

# patron_update: Updates an existing patron record.
# Returns the response hash on success, or undef on failure.
sub patron_update {
    my ($token, $json_payload, $key) = @_;

    unless (defined $token && defined $json_payload && defined $key) {
        $error = "Missing required parameters for patron_update.";
        $code = 0;
        return undef;
    }

    unless ($key =~ /^\d+$/) {
        $error = "Invalid patron key provided for patron_update. Must be numeric.";
        $code = 0;
        return undef;
    }

    return send_post("$base_URL/user/patron/key/$key", $token, $json_payload, 'PUT');
}

# patron_update_activeid: Updates existing patron extended information, specifically active/inactive IDs.
# Returns 1 on success, 0 on failure.
sub patron_update_activeid {
    my ($token, $key, $patron_id, $option) = @_;

    $error = ''; # Clear previous error
    $code  = 0;  # Clear previous code

    unless (defined $token && defined $key && defined $patron_id && defined $option) {
        $error = "Missing required parameters for patron_update_activeid.";
        return 0;
    }

    unless ($key =~ /^\d+$/) {
        $error = "Invalid patron key provided for patron_update_activeid. Must be numeric.";
        return 0;
    }

    unless ($option =~ /^(a|i|d)$/) { # 'a' for add active, 'i' for add inactive, 'd' for delete
        $error = "Invalid option '$option' for patron_update_activeid. Must be 'a', 'i', or 'd'.";
        return 0;
    }

    # Fetch current custom information for the patron
    my $res = send_get("$base_URL/user/patron/key/$key?includeFields=customInformation{*}", $token);

    unless (defined $res) {
        $error = "Failed to retrieve custom information for patron key '$key': $error"; # Propagate error from send_get
        return 0;
    }

    my $custom_info = $res->{'fields'}->{'customInformation'} // []; # Ensure it's an array ref

    my %patron_update_payload = (
        resource => '/user/patron',
        key      => $key,
        fields   => {
            customInformation => [], # Will build this array
        },
    );

    # Process custom information based on the option
    if ($option eq 'a') { # Add to ACTIVEID
        my $found_activeid = 0;
        foreach my $item (@$custom_info) {
            if (defined $item->{'fields'}->{'code'}->{'key'} && $item->{'fields'}->{'code'}->{'key'} eq 'ACTIVEID') {
                my @values = split(/,/, $item->{'fields'}->{'data'} // '');
                push @values, $patron_id;
                $item->{'fields'}->{'data'} = join(',', sort(uniq(@values))); # Add, sort, and unique
                $found_activeid = 1;
                last;
            }
        }
        unless ($found_activeid) {
            # If ACTIVEID doesn't exist, create it
            push @$custom_info, {
                resource => '/user/patron/customInformation',
                fields => {
                    code => { key => 'ACTIVEID', resource => '/policy/patronCustomInformation' },
                    data => $patron_id,
                },
            };
        }
    } elsif ($option eq 'i') { # Add to INACTVID
        my $found_inactvid = 0;
        foreach my $item (@$custom_info) {
            if (defined $item->{'fields'}->{'code'}->{'key'} && $item->{'fields'}->{'code'}->{'key'} eq 'INACTVID') {
                my @values = split(/,/, $item->{'fields'}->{'data'} // '');
                push @values, $patron_id;
                $item->{'fields'}->{'data'} = join(',', sort(uniq(@values))); # Add, sort, and unique
                $found_inactvid = 1;
                last;
            }
        }
        unless ($found_inactvid) {
            # If INACTVID doesn't exist, create it
            push @$custom_info, {
                resource => '/user/patron/customInformation',
                fields => {
                    code => { key => 'INACTVID', resource => '/policy/patronCustomInformation' },
                    data => $patron_id,
                },
            };
        }
    } elsif ($option eq 'd') { # Delete patron_id from any relevant custom ID fields
        my @id_fields_to_clean = qw(ACTIVEID INACTVID PREV_ID PREV_ID2 STUDENT_ID);
        foreach my $item (@$custom_info) {
            if (defined $item->{'fields'}->{'code'}->{'key'} &&
                grep { $_ eq $item->{'fields'}->{'code'}->{'key'} } @id_fields_to_clean)
            {
                my @values = split(/,/, $item->{'fields'}->{'data'} // '');
                my @new_values = grep { $_ ne $patron_id } @values; # Filter out the patron_id
                $item->{'fields'}->{'data'} = join(',', @new_values);
            }
        }
    }

    # Assign the (potentially modified) custom_info back to the payload
    $patron_update_payload{'fields'}{'customInformation'} = $custom_info;

    # Encode the payload as JSON
    my $json_encoder = JSON->new->allow_nonref;
    my $json_str;
    eval {
        $json_str = $json_encoder->encode(\%patron_update_payload);
    };
    if ($@) {
        $error = "Failed to encode JSON for patron_update_activeid: $@";
        return 0;
    }

    # Update the patron
    my $update_res = patron_update($token, $json_str, $key);

    return defined $update_res ? 1 : 0; # Return 1 on success, 0 on failure
}

# Helper for uniq (used in patron_update_activeid)
sub uniq {
    my %seen;
    return grep {!$seen{$_}++} @_;
}

# activity_update: Updates the patron's lastActivityDate.
# Returns the response hash on success, or undef on failure.
sub activity_update {
    my ($token, $json_payload) = @_;

    unless (defined $token && defined $json_payload) {
        $error = "Missing required parameters for activity_update.";
        $code = 0;
        return undef;
    }

    return send_post("$base_URL/user/patron/updateActivityDate", $token, $json_payload, 'POST');
}

# send_get: Creates and sends a standard GET request to the ILSWS API.
# Returns the decoded JSON response hash on success, or undef on failure.
sub send_get {
    my ($url, $token, $params_ref) = @_;

    $error = ''; # Clear previous error
    $code  = 0;  # Clear previous code

    unless (defined $url && defined $token) {
        $error = "Missing required URL or token for send_get.";
        return undef;
    }

    my $full_url = URI->new($url); # Use URI object for robust URL handling

    # Encode and append query parameters if provided
    if (defined $params_ref && ref $params_ref eq 'HASH') {
        # URI->query_form handles encoding automatically
        $full_url->query_form(%{$params_ref});
    }

    if (MODULE_DEBUG_LEVEL >= 2) {
        warn "ILSWS: Sending GET request to: " . $full_url->as_string . "\n";
    }

    # Generate a random request tracker
    my $req_num = 1 + int(rand(1_000_000_000));

    # Define the request headers
    my $req = HTTP::Request->new('GET', $full_url->as_string);
    $req->header('Content-Type'        => 'application/json');
    $req->header('Accept'              => 'application/json');
    $req->header('SD-Originating-App-Id' => $yaml_config->[0]->{'ilsws'}->{'app_id'});
    $req->header('SD-Request-Tracker'  => $req_num);
    $req->header('x-sirs-clientID'     => $yaml_config->[0]->{'ilsws'}->{'client_id'});
    $req->header('x-sirs-sessionToken' => $token);

    # Define the user agent instance
    my $timeout = $yaml_config->[0]->{'ilsws'}->{'timeout'} // DEFAULT_TIMEOUT;
    my $ua = LWP::UserAgent->new(
        timeout             => $timeout,
        ssl_opts            => { verify_hostname => 1 },
        protocols_allowed   => ['https'],
        protocols_forbidden => ['http'],
    );

    # Submit the request
    my $res;
    eval {
        $res = $ua->request($req);
    };
    if ($@) {
        $error = "Exception during HTTP GET request to '$url': $@";
        $code = 0; # Indicate no HTTP response received
        return undef;
    }

    $code = $res->code; # Set the global response code

    my $data = undef;
    if ($res->is_success) {
        # Prepare to deal with JSON
        my $json_parser = JSON->new->allow_nonref;
        eval {
            $data = $json_parser->decode($res->decoded_content);
        };
        if ($@) {
            $error = "Failed to decode JSON response for GET request to '$url': $@. Content: " . $res->decoded_content;
            return undef;
        }
    } else {
        $error = "GET request to '$url' failed: " . $res->status_line . " - " . $res->decoded_content;
    }

    return $data;
}

# send_post: Creates and sends a standard POST/PUT request to the ILSWS API.
# Returns the decoded JSON response hash on success, or undef on failure.
sub send_post {
    my ($url, $token, $query_json, $method) = @_;

    $error = ''; # Clear previous error
    $code  = 0;  # Clear previous code

    unless (defined $url && defined $token && defined $query_json) {
        $error = "Missing required URL, token, or JSON payload for send_post.";
        return undef;
    }

    $method = defined $method ? uc($method) : 'POST'; # Default to POST, ensure uppercase

    unless ($method eq 'POST' || $method eq 'PUT') {
        $error = "Invalid HTTP method '$method' for send_post. Must be 'POST' or 'PUT'.";
        return undef;
    }

    if (MODULE_DEBUG_LEVEL >= 2) {
        warn "ILSWS: Sending $method request to: $url\n";
        warn "ILSWS: Payload: $query_json\n";
    }

    # Generate a random request tracker
    my $req_num = 1 + int(rand(1_000_000_000));

    # Define the request headers
    my $req = HTTP::Request->new($method, $url);
    $req->header('Content-Type'        => 'application/json');
    $req->header('Accept'              => 'application/json');
    $req->header('SD-Originating-App-Id' => $yaml_config->[0]->{'ilsws'}->{'app_id'});
    $req->header('SD-Response-Tracker' => $req_num);
    $req->header('SD-Preferred-Role'   => 'STAFF');
    # Ensure user_privilege_override is defined before using it
    my $priv_override = $yaml_config->[0]->{'ilsws'}->{'user_privilege_override'} // '';
    $req->header('SD-Prompt-Return'    => "USER_PRIVILEGE_OVRCD/$priv_override");
    $req->header('x-sirs-clientID'     => $yaml_config->[0]->{'ilsws'}->{'client_id'});
    $req->header('x-sirs-sessionToken' => $token);
    $req->content($query_json);

    # Define the user agent instance
    my $timeout = $yaml_config->[0]->{'ilsws'}->{'timeout'} // DEFAULT_TIMEOUT;
    my $ua = LWP::UserAgent->new(
        timeout             => $timeout,
        ssl_opts            => { verify_hostname => 1 },
        protocols_allowed   => ['https'],
        protocols_forbidden => ['http'],
    );

    # Print debugging information
    if (MODULE_DEBUG_LEVEL >= 2) {
        warn $req->as_string;
    }

    # Submit the request
    my $res;
    eval {
        $res = $ua->request($req);
    };
    if ($@) {
        $error = "Exception during HTTP $method request to '$url': $@";
        $code = 0; # Indicate no HTTP response received
        return undef;
    }

    $code = $res->code; # Set the global response code

    my $data = undef;
    if ($res->is_success) {
        # Prepare to deal with JSON
        my $json_parser = JSON->new->allow_nonref;
        eval {
            $data = $json_parser->decode($res->decoded_content);
        };
        if ($@) {
            $error = "Failed to decode JSON response for $method request to '$url': $@. Content: " . $res->decoded_content;
            return undef;
        }
    } else {
        $error = "$method request to '$url' failed: " . $res->status_line . " - " . $res->decoded_content;
    }

    return $data;
}

# End of module
1;
