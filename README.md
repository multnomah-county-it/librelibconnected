# ReLibConnectEd
Perl replacement for LibConnectEd

John Houser
john.houser@multco.us

This application monitors for school district uploaded CSV files in 
`/srv/libconnected`, validates and reformats the data as needed, and updates or 
creates records in SirsiDynix Symphony. Record searches, updates, and creates 
are accomplished via the SirsiDynix Web Services API (ILSWS). A local MySQL 
database is utilized to store checksums for the student entries. The checksums
are used to determine if student data has changed between loads. If it hasn't,
no update is performed. If no checksum is found, a checksum is added to the 
MySQL database and the student record is added to the Symphony system.

# Before Installation

These installation notes assume that the software is being installed on an
Ubuntu server. This application requires the following Ubuntu packages be 
installed from the OS distribution. Hint:
```
sudo apt install PACKAGE_NAME
```

- libssl-dev
- mysql-server
- zlib1g-dev

After the mysql-server installation, secure the mysql installation and set
the mysql root password with the following command. Make a note of the root
password! You'll need it to configure the checksum database.
```
sudo mysql_secure_installation
```

This application requires the following modules, which can be downloaded and
installed from CPAN. Hint: 
```
sudo cpan install MODULE_NAME
```

- Data::Dumper
- Date::Calc
- DBI
- DBD::mysql
- Email::Mailer
- File::Find
- File::Basename
- HTTP::Request
- JSON
- Log::Log4perl
- LWP::Protocol::https
- LWP::UserAgent
- Parse::CSV
- Switch
- XML::Simple
- Unicode::Normalize
- URI
- YAML::Tiny

# Installation Notes

1. Copy `relibconnected.pl`, `ingestor.pl`, `config.yaml.sample`, and `log.conf` to the 
desired application directory, usually:
`/opt/relibconnected`
```
relibconnected/
├── AddressFormat.pm
├── bin
│   ├── create_checksum_db.pl
│   └── remove_old_checksums.pl
├── ILSWS.pm
├── README.md
├── config.yaml
├── config.yaml.sample
├── ingestor.pl
├── log
│   ├── ingestor.csv
│   └── mail.log
├── log.conf
├── relibconnected.pl
└─ run
    └── ingestor.flag
```

The `ingester.csv`, `mail.log`, and `ingester.flag` files are created during an 
ingest and deleted automatically afterward. They are shown here for reference.

2. Copy `config.yaml.sample` to `config.yaml` and edit the configuration as 
needed. Be sure to complete this step before moving on to steps 3 and 4.

3. Run `create_checksum_db.pl CONFIG_FILE MYSQL_ROOT_PASSWORD` to create the 
MySQL database used for checksums. For example:
```
bin/create_checksum_db.pl config.yaml 'thisismypassword'
```

4. Run `create_new_user.pl CONFIG_FILE` to create the district user accounts
and incoming directories. For example:
```
bin/create_new_user.pl config.yaml
```

This step will create the upload directory structure, usually 
`/srv/libconnected`. Each school district will have its own directory 
underneath, along with its own incoming subdirectory, into which data files may 
be uploaded. The district accounts are configured so that their home directory 
is the same as their directory under `/srv/libconnected`. 

A sample directory structure might look like this:
```
srv
└── libconnected
    ├── multco03
    │   └── incoming
    ├── multco10
    │   └── incoming
    ├── multco28
    │   └── incoming
    ├── pps00
    │   └── incoming
    ├── pps01
    │   └── incoming
    ├── pps40
    │   └── incoming
    ├── pps99
    │   └── incoming
    └── rsd07
        └── incoming
```

5. Configure the SSHD service to only allow sftp connections for their user 
who are members of the group `sftponly`, which was created by the 
`create_new_user.pl` script. Add the following stanza to the bottom of 
`/etc/ssh/sshd_config` and restart the SSH service:
```
Match group sftponly
  ChrootDirectory /srv/libconnected
  X11Forwarding no
  AllowTcpForwarding no
  ForceCommand internal-sftp -u 0117
```

6. Create `log` and `run` subdirectories (owned by the user that will run the 
software.

7. Create a `relibconnected` subdirectory, accessible to the user that will run 
the software, under `/var/log/`. You may want to add a `relibconnected` 
configuration file under `/etc/logrotate.d/` to avoid uncontrolled log growth.

8. Copy `AddressFormat.pm`,`DataHandler.pm`, and `ILSWS.pm` to `/usr/local/lib/site_perl/` 
or some other directory in the Perl include path. You may need to create 
the directory (as root) if it doesn't already exist. This will put the modules 
into a path where Perl looks for modules. Recent versions of Perl do not, by 
default, look in the current working directory.

9. If you put the application somewhere other than `/opt/relibconnected`, edit 
the paths at the top of `relibconnected.pl` to match the application directory.

10. Edit `config.yaml` as required. Make sure the `base_path` is set to the same
directory as entered in the variable at the top of `relibconnected.pl`. 

11. I don't recommend changing the names or locations of the log files as they 
are defined in `log.conf` unless you change the application `base_path`. If you 
do edit the names or paths to the log files in `log.conf`, you must also change 
them in `ingestor.pl`.

12. Create two cron jobs for the user which owns the application directory. The
first runs relibconnected every 5 minutes to check for uploaded data files. The
second removes expired checksum records from the mysql database based on the
`max_checksum_age` set in `config.yaml`.
For example:
```
*/5 * * * * /opt/relibconnected/relibconnected.pl
15 2 * * * /opt/relibconnected/bin/remove_old_checksums.pl /opt/relibconnected/config.yaml
```

13. One other utility script is included in the bin directory. Run it with the
syntax, `randomize_checksum_ages.pl CONFIG_FILE`. Use this script to spread out the expiration
dates of checksum records so that the software doesn't attempt to update all
the records from a given original load on the same date. The script will 
randomly adjust the `date_added` field in each record forward or backward by up
to seven days. For example:
```
bin/randomize_checksum_ages.pl config.yaml
```

# Configuration Notes

## Field Definition Keywords
When configuring client districts, there a number of keywords that may be used 
to define the way the software will handle incoming data and derivative fields:
* `type`: Symphony field type (used to determine data structure needed in JSON)
* `overlay`: If true, update field when updating existing record
* `validate`: Field validation rule to apply to incoming data (ingestor will throw error and skip record if validation fails)
* `transform`: Transformation function (in ingestor.pl) which takes validated input from one field and returns a valid value
* `overlay_default`: Value to use in update IF FIELD CURRENTLY EMPTY
* `overlay_value`: Value to ALWAYS overlay existing value during update
* `new_default`: Value to use in create IF FIELD CURRENTLY EMPTY
* `new_value`: Value to be used during new create

## Validation Rules

Sample validation rules used in conjunction with the validate field definition keyword:
| Type           | Example              | Comments                 |
| ---            | ---                  | ---                      |
| Date1          | "d:YYYY-MM-DD"       |                          |
| Date2          | "d:YYYY/MM/DD"       |                          |
| Date3          | "d:MM-DD-YYYY"       |                          |
| Date4          | "d:MM/DD/YYYY"       |                          |
| Timestamp1     | "d:YYYY/MM/DD HH:MM" |                          |
| Timestamp2     | "d:YYYY-MM-DD HH:MM" |                          |
| Timestamp3     | "d:YYYYMMDDHHMMSS"   |                          |
| Integer        | "i:8"                | Length of 8              |
| String         | "s:256"              | Max length of 256        |
| List           | "v:01\|11"            | Pipe delimited list of valid entries |
| Blank          | "b"                  | Must be blank            |
| Decimal number | "n:3.2"              | Number(000.00)           |
| Integer range  | "r:1,9999"           | Range between 1 and 9999 |

Note: All dates will be validated against the calendar
