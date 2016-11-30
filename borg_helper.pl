#!/usr/bin/perl -w

use strict;

use JSON;


my @CONFIG_KEYS = (
 [qw {default_repo default_archive dir_config_filenames allowed_owners search_roots archives repos skip_paths}],[]);

my @ARCHIVE_KEYS = (
 [qw {name create_options}],[qw {prune_options}]);

my @REPO_KEYS = (
 [qw {name default_archive repo_path archives}],[qw {prune_options}]);

my @DIR_CONFIG_KEYS = (
    [],[qw {repo archive excludes only_backup}]);

my $dry_run = 0;


main();

sub main
{

    my $config_filename = $ENV{HOME}."/.borg_helper";

    while(@ARGV)
    {
	if($ARGV[0] eq "-c")
	{
	    shift @ARGV;
	    $config_filename = shift @ARGV;
	}
	elsif($ARGV[0] eq "-n")
	{
	    $dry_run = 1;
	    shift @ARGV;
	}
	else { last; }
    }

    if(@ARGV != 2)
    {
	print "Usage: $0 [-n] [-c config-file] <repo> <archive>".'

This helps automate borg. Instead of having a single backup script,
we have backup configuration files scattered throughout the filesystem,
one for each directory tree we want to backup. This way if we reorganize 
directories, or copy data from one server to another, we won\'t have to
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
	"skip_paths":["/sys","/proc","/dev"],
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

ex dir config file2
{
    "repo":"private",
    "archive":"single",
    "only_backup": ["onlyme", "o/onlyme2" ],
    "excludes": ["re:\.o$" ]
}

ex running:

borg_helper.pl private single
```

Note, use BORG_PASSPHRASE environment variable for setting the password for automated backups
';
       exit -1;
    }

    use JSON;

    my ($repo_name, $archive_name) = @ARGV;

    my $config = read_json_file($config_filename);

    standardize_main_config($config_filename, $config);

    print  "Config verified.\n\n";

    my $repo_config = get_named_config($config->{repos},$repo_name);
    my $archive_config = get_named_config($config->{archives},$archive_name);


    my @dir_config_files = search_for_dir_config_files($config->{dir_config_filenames},$config->{allowed_uids},$config->{search_roots}, $config->{skip_paths});

    print  "Found ".(@dir_config_files)." dir files:\n";
    print  join("\n",@dir_config_files)."\n\n";

    my @dir_configs;

    foreach my $file (@dir_config_files)
    {
	my $dc = read_dir_config_file($file);
	standardize_dir_config($file,$dc, $config->{default_repo}, 
			       $config->{default_archive});
	push @dir_configs, $dc;
    }

    check_repo_and_archive($config,@dir_configs);

    my @filtered_dir_configs = 
      grep {$_->{repo} eq $repo_name && $_->{archive} eq $archive_name} @dir_configs;

    print  "Backing up the following directory configs:\n";
    print  join("\n",map($_->{filename},@filtered_dir_configs))."\n\n";

    borg_create_archive($repo_config->{repo_path},\@filtered_dir_configs,
           $archive_config->{create_options},
           $archive_config->{name});

    if($archive_config->{prune_options})
    {
	print "Pruning old backups\n\n";
	borg_prune($repo_config->{repo_path},$archive_name, 
		   @{$archive_config->{prune_options}});
    }
    
    print "Complete!\n";
}

#reads an entire file into a var
sub read_file
{
    my ($filename) = @_;
    my $content;
    open(my $fh, '<', $filename) or die "cannot open file $filename";
    {
        local $/;
        $content = <$fh>;
    }
    close($fh);
    $content;
}

sub read_json_file
{
    my ($filename) = @_;
    my $text = read_file($filename);
    decode_json $text or die "Can't parse json";
}


#verifies main config file is valid and sane'ish
#dies if not
#also standardizes fields
sub standardize_main_config
{
    my ($config_filename, $config) = @_;
    
    verify_keys($config_filename,@CONFIG_KEYS, $config);

    $config->{archive_names} = [];
    foreach my $cat (@{$config->{archives}})
    {
	verify_keys($config_filename."/archives/".$cat->{name},@ARCHIVE_KEYS, $cat);
	push @{$config->{archive_names}}, $cat->{name};
    }
    
    $config->{repo_names} = [];
    foreach my $repo (@{$config->{repos}})
    {
	verify_keys($config_filename."/repos/".$repo->{name},@REPO_KEYS, $repo);
	push @{$config->{repo_names}}, $repo->{name};
    }

    my @uids;
    foreach my $owner (@{$config->{allowed_owners}})
    {
	my $uid = getpwnam($owner);
	defined $uid or die "Can't find uid for username '$owner'";
	push @uids, $uid;
    }

    $config->{allowed_uids} = \@uids;
}

#verifies keys_to_check are in (mand_keys + opt_keys), and mand_keys <= keys_to_check
sub verify_keys
{
    my ($prefix, $mand_keys,$opt_keys,$conf) = @_;

    my %mand_key_hash;
    @mand_key_hash{@$mand_keys} = ();
    my %opt_key_hash;
    @opt_key_hash{@$opt_keys} = ();
    
    foreach my $key (keys %$conf)
    {
	if(!exists $mand_key_hash{$key} &&
	   !exists $opt_key_hash{$key})
	{
	    die "$prefix: Don't understand key '$key'";
	}
    }

    foreach my $key (keys %mand_key_hash)
    {
	die "$prefix: Can't find mandatory key '$key'"
	    unless exists $conf->{$key};
    }
}

#returns the repo config for a particular name
sub get_named_config
{
    my ($configs, $name) = @_;

    foreach my $conf (@$configs)
    {
	if($conf->{name} eq $name)
	{
	    return $conf;
	}
    }

    die "Can't find '$name'";
}

#finds files that match any combination of the  given names with the given owners and the given search roots
#returns filenames
sub search_for_dir_config_files
{
    my ($filenames,$allowed_uids,$search_roots, $skip_paths) = @_;

    use File::Find;

    my %filenames;
    @filenames{@$filenames} = ();

    my %allowed_uids;
    @allowed_uids{@$allowed_uids} = ();

    my %skip_paths;
    @skip_paths{(map { s~/*$~~; $_;} @$skip_paths)} = (); #this enforces skip_paths do not end with '/' and puts them in the hash

    my @out;

    find(
	sub {
	    my $filename = $_;
	    my $dir = $File::Find::dir;
	    my $path = $File::Find::name;

	    if(exists $skip_paths{$path})
	    {
		print STDERR "Skipping $path\n";
		$File::Find::prune = 1;
		return;
	    }

	    if(exists $filenames{$filename})
	    {
		if(!exists $allowed_uids{ (stat($_))[4] })
		{
		    print STDERR "WARNING: Found $filename at $dir with owner: "
			.  getpwuid((stat($_))[4]).", ignoring\n";
		}
		else
		{
		    push @out, $dir."/".$filename;
		}
	    }

	    return 1;
	}, @$search_roots);

    @out;
}


#reads a dir config file
#if only whitespace, returns {}
sub read_dir_config_file
{
    my ($filename) = @_;
    my $file_text = read_file($filename);

    if($file_text =~ m/^\w*$/s)
    {
	return {};
    }

    decode_json $file_text or die "Can't parse json for '$filename'";
}


#verifies per directory config file is valid and sane'ish
#dies if not
#also sets default values for repo, archive and excludes
sub standardize_dir_config
{
    my ($config_filename, $config, $default_repo, $default_archive) = @_;
    
    verify_keys($config_filename,@DIR_CONFIG_KEYS, $config);

    $config->{repo} = $default_repo unless defined $config->{repo};
    $config->{archive} = $default_archive unless defined $config->{archive};
    $config->{excludes} = [] unless defined $config->{excludes};
    $config->{only_backup} = ["."] unless defined $config->{only_backup};
    $config->{filename} = $config_filename;
    $config->{path} = $config_filename;
    $config->{path} =~ s~(.*)/.*~$1/~;
}

sub check_repo_and_archive
{
    my ($config,@dir_configs) = @_;

    my %archives;
    @archives{@{$config->{archive_names}}} = ();

    my %repos;
    @repos{@{$config->{repo_names}}} = ();

    foreach my $dir_config (@dir_configs)
    {
	my $archive = $dir_config->{archive};
	my $repo = $dir_config->{repo};
	die "Can't find archive '$archive' from ".$dir_config->{filename}.
	    " in main config file"
	    unless exists $archives{$archive};
	die "Can't find repo '$repo' from ".$dir_config->{filename}.
	    " in main config file"
	    unless exists $repos{$repo};
    }
}

#this creates an archive using borg
sub borg_create_archive
{
    my ($repo_path,$dir_configs,$borg_options, $archive_name) = @_;

    my @exclude_options = 
	map { create_borg_exclude_options($_->{path}, $_->{excludes});} @$dir_configs;

    my $repo_archive = $repo_path."::".$archive_name."-{now:%Y-%m-%d-%H-%M}";

    my @paths = map { 
	my $path = $_->{path};
	my @only_backup = @{$_->{only_backup}};

	@only_backup = map { s~^/*~/~; $_ } @only_backup;
	
	@only_backup = map { 
	    s~^/*~/~; # one slash at start
	    s~/*$~/~;  # one slash at end
	    s~/\./~~g; # remove any /./
	    
	    s~^/*~~; #remove slash at start
	    s~/*$~~; #remove slash at end
	    $_; } @only_backup;

	map { $path.$_ } @only_backup;
    } @$dir_configs;

    foreach my $p (@paths)
    {
	die "Can't find explicitly included file: $p" unless -e $p;
    }

    run_command(qw { borg create },@$borg_options, 
		(map { ("-e",$_) } @exclude_options), $repo_archive, @paths);
}

sub run_command
{
    my @command = @_;
    if($dry_run)
    {
	print STDERR "**Would run:".join(" ",(map { s/(.*)/'$1'/; $_} @command))."\n";
    }
    else
    {
	print "**Running:".join(" ",(map { s/(.*)/'$1'/; $_} @command))."\n";
	system(@command);
    }
}


sub borg_prune
{
    my ($repo_path, $archive_name, @prune_options) = @_;

    my $repo_archive_prefix = $repo_path."::".$archive_name."-";

    run_command(qw { borg prune --prefix},$repo_archive_prefix,
		@prune_options);
   
}

#converts a path and a directory exclude to a exclude pattern useable by borg that will exclude files that only start from the path given
sub create_borg_exclude_options
{
    my ($path, $excludes) = @_;

    #make sure there is one and only one slash at the end
    $path =~ s~/*$~/~;

    #borg uses a python regular expression, so we need to escape our path
    #in a special way for python
    my $repath = $path;
    $repath =~ s~([^0-9a-zA-Z_ /-])~\\$1~g;
    $repath = "^".$repath;

    map {
	if(/^re:(.*)/)
	{
	    my $re = $1;

	    #if we are pegging against the root
	    if($re =~ /^\^(.*)/)
	    {
		$re = $1;
		#if we start with a directory separator
		if($re =~ /^\/(.*)/)
		{
		    $re = $1;
		}
		
		"re:".$repath.$re;
	    }
	    else {
		#if we start with a directory separator
		if($re =~ /^\/(.*)/)
		{
		    "re:".$repath.$1;
		}
		else {
		    "re:".$repath.".*".$re;
		}
	    }
	}
	else {
	    die "got exclude pattern '$_'. Only 're:...' is accepted for now where ... must be a python regex";
	}
	# elsif(/fm:(.*)/)
	# {
	    
	#     "fm:".$fmpath.$1;
	# }
	# elsif(/sh:(.*)/)
	# {
	#     "sh:".$shpath.$1;
	# }
	# elsif(/pp:(.*)/)
	# {
	#     "pp:".$shpath.$1;
	# }
    } @$excludes;
}
	
