Usage: borg_helper.pl [-n] [-c config-file] <repo> <archive>

This helps automate borg. Instead of having a single backup script,
we have backup configuration files scattered throughout the filesystem,
one for each directory tree we want to backup. This way if we reorganize 
directories, or copy data from one server to another, we won't have to
continually update the corresponding backup script.

For instance, lets say you changed a configuration of your server in
a specific way in some deep down hidden directory. Instead of finding
and updating a global backup script you simply run:

touch BACKUP_DIR

and the automated backup will pick it up and use default settings to
backup the directory. (Assuming that "BACKUP_DIR" is
one of your chosen names for directory backup filenames)

You can add configuration options inside directory specific backup files
if you want to do special things, like have multiple archive types, etc.

All repos and archives mentioned in dir specific config files *must* 
be represented in main config file, or an error will occur. This prevents
typos in dir config files preventing a backup.

* -n dry run
* -c config-file - defaults to ~/.borg_helper
* repo - repo to backup
* archive - This value filters the dir_config_files to use. Only dir_config_files
with a matching archive will be backed up. (The idea here is to have a separate archive for long lived backups with historical data vs prunable backups without)


Pruning:

Pruning will be done automatically after a successful backup for the given archive. A prune will only be done if the archive has a "prune_options" variable 


```
ex config file
{
    "default_repo":"private",
    "dir_config_filenames":["TIMBACKUP"],
    "allowed_owners":["tim","user","root"]
	"search_roots":["/"]
	"archives":[{"name":"single", 
		     "prune_options":"-d 1"}
	],
    "repos":[
	{"name":"private",
	 "default_archive":"full",
	 "repo_path":"/repo",
	 "archives":["full","single","double"]
	},
	{"name":"autonomicwiki",
	 "default_archive":"full",
	 "archives":["full","single"]
	}
	]
}

ex dir config file
{
    "repo":"private",
    "archive":"single",
    "excludes": ["re:\.o$" ]
}

ex running:

borg_helper.pl private single
```

Note, use BORG_PASSPHRASE environment variable for setting the password for automated backups
