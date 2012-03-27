#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Std;
use Parse::RecDescent;
use Data::Dumper;
use File::Copy;

my %opts;
getopts("co:", \%opts) or
    die "Usage: $0 [-c] <input-file>\n";

my $compile_only = $opts{c};
my $outfile = $opts{o} || "a.pl";

my $parser = Parse::RecDescent->new(<<'END_GRAMMAR');
spec: entity(s?) eof { $item[1] }
    | <error>

eof: /^\Z/

entity: identifier block { [$item[1], $item[2]] }

block: '{' rule(s?) '}' { $item[2] }
     | <error>

rule: command argument(s?) ';' { [$item[1], $item[2]] }
    | <error>

command: 'git'
       | 'file'
       | 'dir'
       | 'dep'
       | 'yum'
       | 'prog'
       | <error>

argument: /"(?:\\.|[^\\"])*"/ { eval $item[1] }
        | /'(?:\\.|[^\\'])*'/ { eval $item[1] }
        | /[^;\s]+/
        | <error>

identifier: /[A-Za-z][-\w]*/
          | <error>

END_GRAMMAR

my $infile = shift or
    die "No input file specified.\n";

open my $in, $infile or
    die "Cannot open $infile for reading: $!\n";

my $src = do { local $/; <$in> };

my $ast = $parser->spec($src) or
    die "Failed to parse $infile: Bad grammar.\n";

#print Dumper($ast);

my $default_goal;
my %entities;
for my $entity (@$ast) {
    my ($name, $rules) = @$entity;
    if (!$default_goal) {
        $default_goal = $name;
    }

    #warn "entity: $name\n";
    if ($entities{$name}) {
        die "entity $name redefined.\n";
    }

    my %rules;

    $entities{$name} = \%rules;

    for my $rule (@$rules) {
        my ($cmd, $args) = @$rule;
        if ($rules{$cmd}) {
            push @{ $rules{$cmd} }, @$args;

        } else {
            $rules{$cmd} = $args;
        }
    }

    my $deps = $rules{dep};

    my $gits = $rules{git};
    if ($gits) {
        if (!$deps) {
            $rules{dep} = ['git'];
        } else {
            unshift @$deps, 'git';
        }
    }
}

for my $name (keys %entities) {
    my $rules = $entities{$name};
    my $deps = $rules->{dep};
    if ($deps) {
        for my $dep (@$deps) {
            if (!$entities{$dep}) {
                die "Entity $dep is required by $name but is not defined.\n";
            }
        }
    }
}

#warn "default goal: $default_goal\n";

open my $out, ">$outfile" or
    die "Cannot open $outfile for writing: $!\n";

my $data = \*DATA;
while (<$data>) {
    print $out $_;
}

print $out "\$default_goal = '$default_goal';\n";
print $out Data::Dumper->Dump([\%entities], ['entities']);
print $out "main()";
close $out;

__DATA__
#!/usr/bin/env perl

use 5.006001;
use strict;
use warnings;

my ($default_goal, $entities);
my $check_only;

my (%made, %making);

sub make ($);
sub check_dir ($);
sub main ();

sub make ($) {
    my $target = shift;

    if ($made{$target}) {
        return;
    }

    if ($making{$target}) {
        die "Circular dependency found around $target\n";
    }

    $making{$target} = 1;

    my $rules = $entities->{$target};
    if (!$rules) {
        die "entity $rules not defined.\n";
    }

    my $deps = $rules->{dep};

    my $gits = $rules->{git};
    if ($gits) {
        if (!$deps) {
            $rules->{dep} = ['git'];
        } else {
            unshift @$deps, 'git';
        }
    }

    if ($deps) {
        for my $dep (@$deps) {
            make($dep);
        }
    }

    warn "making $target ...\n";

    my $dirs = $rules->{dir};
    if ($dirs) {
        for my $dir (@$dirs) {
            check_dir($dir);
        }
    }

    if ($gits) {
        if (@$gits % 2 != 0) {
            die "Bad number of arguments to the \"git\" command: ",
                scalar(@$gits);
        }

        my @args = @$gits;
        while (@args) {
            my $url = shift @args;
            my $dir = shift @args;

            $dir =~ s/^~/$ENV{HOME}/;
            if (!good_git_repos($dir)) {
                if (-d $dir) {
                    sh("rm", "-rf", $dir);
                }

                sh("git", "clone", $url, $dir);
            }
        }
    }

    $made{$target} = 1;
}

sub sh (@) {
    if ($check_only) {
        print "@_\n";

    } else {
        if (system(@_) != 0) {
            die "failed to run command: $?\n";
        }
    }
}

sub good_git_repos ($) {
    my $dir = shift;
    if (-d $dir && -d "$dir/.git"
        && -d "$dir/.git/refs" && -d "$dir/.git/objects") {
        #print "good git repos $dir.\n";
        return 1;
    }

    return undef;
}

sub check_dir ($) {
    my $dir = shift;
    $dir =~ s/^~/$ENV{HOME}/;
    if (-d $dir) {
        print "Directory $dir exists.\n";

    } else {
        print "Directory $dir NOT exists.\n";
    }
}

sub main () {
    my $cmd = shift @ARGV or
        die "No command specified.\n";

    if ($cmd eq 'check') {
        $check_only = 1;

        make($default_goal);

    } elsif ($cmd eq 'make') {
        undef $check_only;

        make($default_goal);

    } else {
        die "unknown command: $cmd\n";
    }
}

