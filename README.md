# ReLibConnectEd (librelibconnected)

Perl automated pipeline for ingesting school district student data into SirsiDynix Symphony ILS.

**Author:** John Houser (john.houser@multco.us)  
**Copyright:** Multnomah County 2025  

---

## Table of Contents

- [Overview](#overview)
- [Architecture & Data Flow](#architecture--data-flow)
- [Directory Structure](#directory-structure)
- [Prerequisites & Dependencies](#prerequisites--dependencies)
- [Installation & Setup](#installation--setup)
- [Utility Scripts (`bin/`)](#utility-scripts-bin)
- [Configuration Reference (`config.yaml`)](#configuration-reference-configyaml)
- [Field Definition Keywords & Validation Rules](#field-definition-keywords--validation-rules)
- [Logging & Error Handling](#logging--error-handling)

---

## Overview

**ReLibConnectEd** (`librelibconnected`) monitors for school district student data CSV files uploaded via SFTP into subdirectories under `/srv/libconnected`.

Upon detecting an uploaded CSV file, the application:
1. Validates the data schema and applies field-level validation and truncation rules.
2. Formats and standardizes address components to conform with USPS standards (via `AddressFormat.pm`).
3. Computes MD5 checksums (digests) for student records and compares them against a local MySQL database. If a student's data hasn't changed since the previous load, processing for that student is skipped.
4. Performs multi-tier patron searches and updates or creates patron records in SirsiDynix Symphony using the SirsiDynix Web Services API (`ILSWS.pm`).
5. Generates run statistics and sends an email report (with log attachments via `MIME::Lite`) to administrators and district contacts.
6. Cleans up ingested files and temporary logs.

---

## Architecture & Data Flow

### 1. Ingestion Flow Diagram

```
[ School District ] --(SFTP Upload)--> /srv/libconnected/<district>/incoming/*.csv
                                                |
                                          (Cron Trigger)
                                                v
                                       relibconnected.pl
                                 (Atomic Locking & Taint Mode)
                                                |
                                                v
                                           ingestor.pl
                                                |
                +-------------------------------+-------------------------------+
                |                               |                               |
                v                               v                               v
          AddressFormat.pm                 MySQL Database                   ILSWS.pm
     (USPS Address Formatting)         (MD5 Checksum Matching)       (SirsiDynix Symphony API)
                |                               |                               |
                +-------------------------------+-------------------------------+
                                                |
                                                v
                                           MIME::Lite
                                   (Email Ingest Report & Logs)
```

### 2. Core Components

- **`relibconnected.pl`**: The cron-driven wrapper entrypoint.
  - Operates under Perl Taint mode (`-T`).
  - Uses atomic lock creation (`sysopen` with `O_CREAT|O_EXCL` and advisory `flock`) at `/opt/librelibconnected/run/ingestor.lock` to prevent concurrent process collisions.
  - Scans `/srv/libconnected` for incoming CSV files and safely invokes `ingestor.pl` using list-form `system()` execution to prevent shell injection.

- **`ingestor.pl`**: The primary data ingestion engine.
  - Loads `config.yaml` and initializes Log4perl logging.
  - Maps incoming CSV headers to the configured schema (`district` or `pps`).
  - Connects to SirsiDynix Symphony ILSWS and the local MySQL checksum database.
  - Processes student records line-by-line: validates, formats addresses, computes MD5 digests, searches for matching patrons, updates existing records or creates new ones.
  - Emails run reports with attached logs (`mail.log` and `ingestor.csv`) to configured admin and district contacts.
  - Safely deletes temporary log files and the processed CSV file.

- **`ILSWS.pm`**: Custom API client for SirsiDynix Web Services.
  - Handles authentication, session tokens, patron searches (Alt ID, Email, Barcode, DOB + Street), patron creation, and patron updates.

- **`AddressFormat.pm`**: Package for standardizing street address strings to USPS standards.
  - Handles trimming whitespace, stripping non-standard punctuation, standardizing compass directionals (e.g., "N", "SE"), abbreviating street types (e.g., "Avenue" -> "Ave"), normalizing apartment/unit designations, and title-casing street names.

- **`DataHandler.pm`**: Package for evaluating mapping tables and validating dates, strings, numbers, and ranges.

---

## Directory Structure

Default installation path: `/opt/librelibconnected`

```
/opt/librelibconnected/
├── AddressFormat.pm          # USPS address formatting module
├── DataHandler.pm            # Data mapping and validation module
├── ILSWS.pm                  # SirsiDynix Web Services API wrapper
├── README.md                 # System documentation
├── config.yaml               # Application configuration file
├── config.yaml.sample        # Sample configuration template
├── ingestor.pl               # Main CSV ingestion engine
├── log.conf                  # Log4perl configuration file
├── relibconnected.pl         # Secure wrapper / cron entrypoint
├── bin/                      # Administrative and utility scripts
│   ├── create_checksum_db.pl     # Database initialization script
│   ├── create_new_user.pl        # District SFTP user setup script
│   ├── randomize_checksum_ages.pl# Digest expiration jitter tool
│   ├── remove_old_checksums.pl   # Expired digest purge tool
│   ├── report_checksum_dates.pl  # Digest distribution reporting tool
│   ├── stuck_clear.pl            # Stuck flag and stale log recovery
│   ├── stuck_warn.pl             # Stale file monitoring and alerting
│   ├── stuck_clear.txt           # Notification template for stuck_clear
│   └── stuck_warn.txt            # Notification template for stuck_warn
├── log/                      # Application log directory
│   ├── ingestor.csv          # Per-run CSV audit log (auto-generated)
│   └── mail.log              # Per-run email log summary (auto-generated)
└── run/                      # Process lock file directory
    └── ingestor.lock         # Atomic lock file created during ingest
```

SFTP Directory Structure: `/srv/libconnected`

```
/srv/libconnected/
├── <namespace><id>/          # e.g., pps40, multco03
│   ├── .ssh/
│   │   └── authorized_keys   # District SSH key
│   └── incoming/             # Target upload directory for district CSV files
```

---

## Prerequisites & Dependencies

### System Requirements

This software is designed for **Ubuntu Server** (or Debian-based Linux systems). The following OS packages are required:

```bash
sudo apt update
sudo apt install mysql-server libssl-dev zlib1g-dev sendmail
```

After installing `mysql-server`, secure the installation and note the root password:

```bash
sudo mysql_secure_installation
```

### Perl CPAN Dependencies

The application requires Perl 5.10+ and the following CPAN modules:

```bash
sudo cpan install Data::Dumper Date::Calc DBI DBD::mysql Digest::MD5 \
  Email::Valid File::Basename File::Find HTTP::Request JSON \
  Log::Log4perl LWP::Protocol::https LWP::UserAgent MIME::Lite \
  Parse::CSV Readonly Text::CSV_XS Try::Tiny Unicode::Normalize URI YAML::Tiny
```

---

## Installation & Setup

1. **Deploy Application Directory**:
   Copy all repository files to `/opt/librelibconnected` (or your preferred base path):
   ```bash
   sudo mkdir -p /opt/librelibconnected
   sudo cp -r * /opt/librelibconnected/
   ```

2. **Configure Modules in Perl Path**:
   Copy `AddressFormat.pm`, `DataHandler.pm`, and `ILSWS.pm` to `/usr/local/lib/site_perl/` or ensure `/opt/librelibconnected` is included in Perl's `@INC` path:
   ```bash
   sudo cp AddressFormat.pm DataHandler.pm ILSWS.pm /usr/local/lib/site_perl/
   ```

3. **Set Up Logging Directory**:
   Create the system log directory and set permissions for the service user running the application:
   ```bash
   sudo mkdir -p /var/log/relibconnected
   sudo chown -R libconnected:libconnected /var/log/relibconnected
   ```

4. **Configure `config.yaml`**:
   Copy `config.yaml.sample` to `config.yaml` and update values for admin contacts, ILSWS API credentials, MySQL credentials, SMTP settings, and district configurations:
   ```bash
   cd /opt/librelibconnected
   cp config.yaml.sample config.yaml
   nano config.yaml
   ```

5. **Initialize MySQL Digest Database**:
   Run `create_checksum_db.pl` as root, supplying the config file path and MySQL root password:
   ```bash
   sudo bin/create_checksum_db.pl /opt/librelibconnected/config.yaml 'MYSQL_ROOT_PASSWORD'
   ```

6. **Create District SFTP Accounts & Upload Directories**:
   Run `create_new_user.pl` as root to configure district system accounts and `/srv/libconnected/<district>/incoming` directories:
   ```bash
   sudo bin/create_new_user.pl /opt/librelibconnected/config.yaml
   ```

7. **Configure SSH SFTP Chroot**:
   Restrict district users to SFTP access only by adding the following stanza at the bottom of `/etc/ssh/sshd_config` and restarting the SSH service (`sudo systemctl restart ssh`):
   ```etc
   Match group sftponly
     ChrootDirectory /srv/libconnected
     X11Forwarding no
     AllowTcpForwarding no
     ForceCommand internal-sftp -u 0117
   ```

8. **Schedule Cron Jobs**:
   Set up crontab entries for the service user running `relibconnected`:
   ```crontab
   # Check for incoming student data files every 5 minutes
   */5 * * * * /opt/librelibconnected/relibconnected.pl

   # Purge expired checksum digests daily at 2:15 AM
   15 2 * * * /opt/librelibconnected/bin/remove_old_checksums.pl /opt/librelibconnected/config.yaml

   # Check for stuck incoming files (>90 mins) every hour
   0 * * * * /opt/librelibconnected/bin/stuck_warn.pl
   ```

---

## Utility Scripts (`bin/`)

The `bin/` directory contains administrative tools:

| Script | Execution Context | Usage / Syntax | Description |
| --- | --- | --- | --- |
| `create_checksum_db.pl` | Setup (Root) | `sudo bin/create_checksum_db.pl CONFIG_FILE MYSQL_ROOT_PASS` | Creates the MySQL database, application user, grants privileges, and initializes the `checksums` table. |
| `create_new_user.pl` | Setup (Root) | `sudo bin/create_new_user.pl CONFIG_FILE` | Creates district system user accounts, `sftponly` group, directory trees under `/srv/libconnected`, and SSH `authorized_keys`. |
| `remove_old_checksums.pl` | Cron / Admin | `bin/remove_old_checksums.pl CONFIG_FILE` | Deletes MD5 checksum entries older than `max_checksum_age` (from `config.yaml`), forcing full re-checks on next upload. |
| `randomize_checksum_ages.pl` | Admin | `bin/randomize_checksum_ages.pl CONFIG_FILE` | Randomly adjusts `date_added` in `checksums` by up to ±29 days to stagger record expiration dates and avoid update spikes. |
| `report_checksum_dates.pl` | Admin | `bin/report_checksum_dates.pl CONFIG_FILE` | Summarizes and prints record count totals grouped by `date_added` in the checksum database. |
| `stuck_warn.pl` | Cron / Admin | `bin/stuck_warn.pl` | Scans `/srv/libconnected` for incoming CSV files older than 90 minutes and emails an administrative warning. |
| `stuck_clear.pl` | Admin | `bin/stuck_clear.pl` | Recovers from stale lock/flag states, archives older logs with timestamps, and notifies administration. |

---

## Configuration Reference (`config.yaml`)

### Global Configuration Keys

```yaml
admin_contact: Admin Contact <admin@example.org> # Email address for system alerts
base_path: /opt/librelibconnected                 # Application base directory
incoming_path: /srv/libconnected                  # SFTP base directory
log_level: info                                   # Logging verbosity (debug|info|warn|error|fatal)
service_account: libconnected                     # Linux service user owning incoming folders
adult_profile: 0_MULT                             # Default adult patron profile ID

ilsws:                                            # SirsiDynix Web Services API credentials
  username: API_USER
  password: API_PASSWORD
  hostname: ilsws.example.org
  port: 443
  webapp: symphony
  client_id: CLIENT_ID
  app_id: relibconnected
  user_privilege_override: OVERRIDE
  timeout: 40
  max_retries: 3

mysql:                                            # Local Digest Database settings
  hostname: localhost
  port: 3306
  db_name: libconnected_checksums
  db_username: libconnected
  db_password: DB_PASSWORD
  max_checksum_age: 90                            # Digest expiration in days

smtp:                                             # Mail transfer settings
  hostname: smtp.example.org
  port: 25
  from: libconnected@example.org
  user: ''
  pass: ''
```

### Client / District Configuration Structure

Each district entry under `clients:` defines authentication, contact information, schema mapping, and field-level rules:

```yaml
clients:
  - id: '40'
    authorized_key: "ssh-rsa AAAAB3NzaC1yc2E..."
    namespace: pps
    schema: district                              # Schema type: 'district' or 'pps'
    name: DDSD
    contact: District Contact <district@example.org>
    email_reports: false                          # Set true to send ingest report to client contact
    email_pattern: example.org
    fields:
      barcode:
        type: string
        overlay: true
        validate: s:14
        transform: c:transform_barcode
      street:
        type: address
        overlay: true
        validate: s:128
        transform: c:transform_street             # Formats address to USPS standards
        new_default: "205 NE Russell St"
```

---

## Field Definition Keywords & Validation Rules

### Field Definition Keywords

When configuring client districts in `config.yaml`, the following keywords define field behavior:

| Keyword | Description |
| --- | --- |
| `type` | Symphony field type (determines JSON structure sent to API). |
| `overlay` | Boolean (`true`/`false`). Controls whether this field is updated when an existing patron record is modified. |
| `validate` | Validation rule string applied to incoming CSV data. Invalid records trigger warnings and skipping. |
| `transform` | Transformation function in `ingestor.pl` (e.g., `c:transform_street` or `c:transform_barcode`). |
| `overlay_default` | Fallback value to insert during an update if the field in Symphony is currently empty. |
| `overlay_value` | Static value that ALWAYS overwrites the field during an update. |
| `new_default` | Fallback value to use during new patron creation if the field is empty in incoming data. |
| `new_value` | Static value ALWAYS used when creating a new patron. |

### Validation Rules Reference

Validation rules used with the `validate` keyword:

| Rule Type | Syntax / Example | Description / Constraints |
| --- | --- | --- |
| Date Format 1 | `d:YYYY-MM-DD` | ISO date validation (validated against calendar). |
| Date Format 2 | `d:YYYY/MM/DD` | Slash-separated ISO date. |
| Date Format 3 | `d:MM-DD-YYYY` | US hyphenated date. |
| Date Format 4 | `d:MM/DD/YYYY` | US slash-separated date. |
| Timestamp 1 | `d:YYYY/MM/DD HH:MM` | Date and time (24h). |
| Timestamp 2 | `d:YYYY-MM-DD HH:MM` | ISO date and time. |
| Timestamp 3 | `d:YYYYMMDDHHMMSS` | Full numeric timestamp. |
| Integer | `i:8` | Fixed length integer. |
| String | `s:256` | Maximum string character length (e.g. max 256 chars). |
| Value List | `v:01\|11` | Pipe-delimited list of allowed literal string values. |
| Blank | `b` | Field must be completely blank or empty. |
| Decimal Number | `n:3.2` | Number with specific precision/scale (e.g., 000.00). |
| Integer Range | `r:1,9999` | Integer value bounded inclusively between min and max. |

---

## Logging & Error Handling

Logging is driven by `Log::Log4perl` using the configuration in `log.conf`:

- **System Log**: Written to `/var/log/relibconnected/ingestor.log`. Logs full operational details, warnings, errors, and debug statements.
- **Mail Summary Log**: Generated per run at `/opt/librelibconnected/log/mail.log` and attached to report emails.
- **CSV Audit Log**: Generated per run at `/opt/librelibconnected/log/ingestor.csv` detailing actions taken (`create`, `update`, `skip`) for each record.
- **Email Notification**: On completion, `ingestor.pl` compiles the run statistics and emails `mail.log` and `ingestor.csv` via `MIME::Lite`.
