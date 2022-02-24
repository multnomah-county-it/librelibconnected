# relibconnected
Perl replacement for LibConnectEd

This application is designed to monitor for school district uploaded CSV files, 
validate and reformat records, and update or create records in SirsiDynix 
Symphony, via their Web Services API.

INSTALLATION INSTRUCTIONS

1. Copy relibconnected.pl, ingestor.pl, config.yaml.sample, and log.conf to the 
desired application directory, usually:
/opt/relibconnected

2. Copy AddressFormat.pm and ILSWS.pm to /usr/local/lib/site_perl/. Create the
directory if it doesn't already exist.

3. If you put the application somewhere other than /opt/relibconnected, edit 
the paths at the top of relibconnected.pl to match the application directory.

4. Copy config.yaml.sample to config.yaml.

5. Edit config.yaml as desired. Make sure the base_path is set to the same
directory as entered in the variable at the top of relibconnected.pl.

6. You should not need to edit the log file names. If you do edit the names of 
the log files in log.conf, you must also change them in ingestor.pl.

7. Create a cron job for the user which owns the application directory to
run relibconnected.pl every five minutes. For example:
*/5 * * * * /opt/relibconnected
