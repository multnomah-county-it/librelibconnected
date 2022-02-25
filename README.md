# relibconnected
Perl replacement for LibConnectEd

John Houser
john.houser@multco.us

(This file looks better as raw, due to the trees.)

This application monitors for school district uploaded CSV files in 
/srv/libconnected, validates and reformats the data as needed, and updates or 
creates records in SirsiDynix Symphony. Record searches, updates, and creates 
are accomplished via the SirsiDynix Web Services API (ILSWS).

BEFORE INSTALLATION

This application requires the following modules, which can be downloaded and
installed from CPAN. Hint: sudo cpan install MODULE_NAME

File::Basename
Log::Log4perl
YAML::Tiny
Parse::CSV
Date::Calc
Email::Mailer
Switch
Data::Dumper
Unicode::Normalize

INSTALLATION NOTES

1. Copy relibconnected.pl, ingestor.pl, config.yaml.sample, and log.conf to the 
desired application directory, usually:
/opt/relibconnected

relibconnected/
├── AddressFormat.pm
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

The ingester.csv, mail.log, and ingester.flag files are created during an 
ingest and deleted automatically afterward.

2. Create log and run subdirectories (owned by the user that will run the 
software.

3. Create a relibconnected subdirectory, accessible to the user that will run 
the software, under /var/log/.

4. Create the upload directory structure, usually /srv/libconnected. Each 
school district should have its own directory underneath, with its own incoming 
directory, into which data files may be uploaded. The district accounts should
be configured so that their home directory is their directory under 
libconnected. Configure the SSHD service to only allow sftp connections for 
their user. A sample directory structure might look like this:

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

5. Copy AddressFormat.pm and ILSWS.pm to /usr/local/lib/site_perl/. Create the
directory (as root) if it doesn't already exist. This will put the modules into 
a path where Perl looks for modules. Recent versions of Perl do not, by default, 
look in the current working directory.

6. If you put the application somewhere other than /opt/relibconnected, edit 
the paths at the top of relibconnected.pl to match the application directory.

7. Copy config.yaml.sample to config.yaml.

8. Edit config.yaml as required. Make sure the base_path is set to the same
directory as entered in the variable at the top of relibconnected.pl. I don't
recommend changing the names or locations of the log files as they are defined
in log.conf.

9. If you do edit the names of the log files in log.conf, you must also change 
them in ingestor.pl.

10. Create a cron job for the user which owns the application directory to
run relibconnected.pl every five minutes. For example:
*/5 * * * * /opt/relibconnected/relibconnected.pl
