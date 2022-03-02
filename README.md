# ReLibConnectEd
Perl replacement for LibConnectEd

John Houser
john.houser@multco.us

This application monitors for school district uploaded CSV files in 
`/srv/libconnected`, validates and reformats the data as needed, and updates or 
creates records in SirsiDynix Symphony. Record searches, updates, and creates 
are accomplished via the SirsiDynix Web Services API (ILSWS).

# Before Installation

This application requires the follow Ubuntu packages be installed from the OS
distribution. Hint:
```
sudo apt install PACKAGE_NAME
```

- libssl-dev
- mysql-server
- zlib1g-dev

After the mysql-server installation, secure your mysql installation and set
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
- XML::Hash::LX
- Unicode::Normalize
- URI::Encode
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
ingest and deleted automatically afterward.

2. Run `create_checksum_db.pl` to create the mysql database used for checksums.
```
./create_checksum_db.pl ../config.yaml MYSQL_ROOT_PASSWORD
```

3. Create `log` and `run` subdirectories (owned by the user that will run the 
software.

4. Create a `relibconnected` subdirectory, accessible to the user that will run 
the software, under `/var/log/`. You may want to add a `relibconnected` 
configuration file under `/etc/logrotate.d/` to avoid uncontrolled log growth.

5. Create the upload directory structure, usually `/srv/libconnected`. Each 
school district should have its own directory underneath, with its own incoming 
directory, into which data files may be uploaded. The district accounts should
be configured so that their home directory is their directory under 
libconnected. Configure the SSHD service to only allow sftp connections for 
their user. A sample directory structure might look like this:
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
6. Copy `AddressFormat.pm` and `ILSWS.pm` to `/usr/local/lib/site_perl/`. Create the
directory (as root) if it doesn't already exist. This will put the modules into 
a path where Perl looks for modules. Recent versions of Perl do not, by default, 
look in the current working directory.

7. If you put the application somewhere other than `/opt/relibconnected`, edit 
the paths at the top of `relibconnected.pl` to match the application directory.

8. Copy `config.yaml.sample` to `config.yaml`.

9. Edit `config.yaml` as required. Make sure the `base_path` is set to the same
directory as entered in the variable at the top of `relibconnected.pl`. I don't
recommend changing the names or locations of the log files as they are defined
in `log.conf`.

10. If you do edit the names of the log files in `log.conf`, you must also change 
them in `ingestor.pl`.

11. Create two cron jobs for the user which owns the application directory. The
first runs relibconnected every 5 minutes to check for uploaded data files. The
second removes expired checksum records from the mysql database based on the
`max_checksum_age` set in `config.yaml`.
For example:
```
*/5 * * * * /opt/relibconnected/relibconnected.pl
15 2 * * * /opt/relibconnected/bin/remove_old_checksums.pl /opt/relibconnected/config.yaml
```
