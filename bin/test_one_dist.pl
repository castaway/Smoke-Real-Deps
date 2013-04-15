#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper;
use MetaCPAN::API;
use CPAN;
use Module::CoreList;

## This script or whatever it is only gets run for *one* module,
## else we should save $ENV{PERL5LIB} and repeatedly call ->import
use local::lib '~/smoke_exact_deps';
use lib::core::only;

$CPAN::DEBUG=1;
$Data::Dumper::Terse=1;

CPAN::HandleConfig->load;
CPAN::Shell::setup_output;
CPAN::Index->reload;

## Fun!

my $module_name = shift || 'Dist::Zilla';

#my ($result) = CPAN::Shell->expand('Module', 'Dist::Zilla');
## Bad version hashes?
# explorer.metacpan.org/?url=%2Ffile%2F_search&content=%7B%0D%0A++%22query%22+%3A+%7B+%22filtered%22+%3A+%7B%0D%0A++++++%22query%22+%3A+%7B%22match_all%22+%3A+%7B%7D%7D%2C%0D%0A++++++%22filter%22+%3A+%7B%0D%0A+++++++++++%22and%22+%3A+%5B%0D%0A+++++++++++++++%7B%22term%22+%3A+%7B%22file.module.name%22+%3A+%22Text%3A%3ABalanced%22%7D%7D%2C%0D%0A+++++++++++++++%7B%22term%22+%3A+%7B%22file.module.version%22+%3A+%222.0.0%22+%7D%7D%0D%0A++++++++++++++++++%5D%7D%0D%0A+++++++%7D%7D%2C%0D%0A+++++++%22fields%22+%3A+%5B%22release%22%2C+%22author%22%5D%0D%0A%7D
#my ($result) = CPAN::Shell->expand('Module', 'DBIx::Class');
## Text::Balanced 2.00 doesn't exist - it's 2.0.0 in $VERSION

# my ($result) = CPAN::Shell->expand('Module', 'Moo');
#my ($result) = CPAN::Shell->expand('Module', 'MetaCPAN::API');

#my ($result) = CPAN::Shell->expand('Module', 'CPAN::FindDependencies');
my ($module) = CPAN::Shell->expand('Module', $module_name);
my ($downloads) = get_download_urls($module);


$CPAN::Config->{prerequisites_policy} = 'follow';
$CPAN::Config->{urllist} = ['http://backpan.cpantesters.org'];
$CPAN::META->has_inst('Digest::SHA', 'no');
foreach my $url (@$downloads) {
    $url =~ s{http://cpan.metacpan.org/authors/id/\w/\w\w/}{};
    ## This wants to download CHECKSUMs which backpan doesn't have..
    ## If Digest::SHA isn't availabe it won't try
    warn "Installing dep $url\n";
    CPAN::Shell->install($url);
#    `cpanm -L ~/smoke_exact_deps $url`;
}

$CPAN::Config->{prerequisites_policy} = 'ignore';
$module->distribution->test();

sub get_download_urls {
    my ($module) = @_;

#    print ref $module->distribution, "\n";

    ## We actually only want to fetch and parse the Makefile/Build.PL, but there isn't
    ## a separate call for that

    #$result->get();
    $module->make();
    my $reqs = $module->distribution->prereq_pm()->{requires};
    my $api = MetaCPAN::API->new;

    # print Dumper($module->distribution->prereq_pm);

    my @downloads = ();
    foreach my $req (keys %$reqs) {
#        print "Hunting.. $req\n";

        if($req eq 'perl') {
            warn "Perl required, skipping\n";
            delete $reqs->{$req};
            next;
        };
        if(exists $Module::CoreList::version{$]}{$req}) {
            warn "Module is in core on this Perl ($]), skipping\n";
            delete $reqs->{$req};
            next;
        }
    
        my @releases;
        if($reqs->{$req} == 0) {
        ## Means "any" version, so we'll be annoying and try the earliest on CPAN

            my ($mod) = $api->fetch("module/$req?fields=distribution");
#        print Dumper($mod);
#        my $dist = $mod->{hits}{hits}[0]{fields}{distribution};
            my $dist = $mod->{distribution};
#            print "Converted $req to $dist\n";
            if($dist eq 'perl') {
                warn "Ignoring perl dep ($req)\n";
                delete $reqs->{$req};
                next;
            }
            ## More than one as we later parse for "authorized", can we add it to the filter and only fetch 1?
#        my $releases = $api->fetch("release/_search?q=distribution:$dist&sort=version_numified:asc&size=1");
            my $releases = $api->fetch("release/_search?q=distribution:$dist&sort=version_numified:asc&size=500");
#        print Dumper($releases);
            my @left;
            foreach my $release (@{ $releases->{hits}{hits} }) {
                ## Want to ignore backpan,if possible
                if($release->{_source}{authorized} eq 'true') {
                    push @left, $release;
                    last;
                }
            }
            if(!@left) {
                warn "No authorized releases for $dist\n";
            }
            @releases= map { $_->{_source} } @left;
#        @releases = @{ $releases->{hits}{hits} };
            if (!@releases) {
                die "Can't find any releases for $dist";
            }
        } else {
            my $stuff = $api->post('file/_search',{
                "query" => { "filtered" => {
                    "query" => {"match_all" => {}},
                    "filter" => {
                        "and" => [
                            {"term" => {"file.module.name" => $req}},
                            {"numeric_range" => 
                             {"file.module.version_numified" => { from => $reqs->{$req} }},
                            },
                        {"term" => {"file.authorized" => "true"}},
                         {"not" => {"term" => {"file.maturity" => "developer"}}},
##                        {"not" => {"term" => {"file.status" => "backpan"}}}
                            ]}
                             }},
                "fields" => ["release", "author", "status"],
                "sort" => { "file.module.version_numified" => "asc" },
                "size" => 1,
                                   });
            
#        print Dumper($stuff);
            @releases = map {
                my $fields = $_->{fields};
                #           next if($fields->{status} eq 'backpan');
                my $release = $api->fetch('release/'.$fields->{author}.'/'.$fields->{release}); #.'&fields=maturity,authorized,download_url');
            } @{ $stuff->{hits}{hits} };
#        print Dumper(\@releases);
        }
    
        if(@releases > 1) {
            warn "Too many results for $req, removing unauthoried\n";
#        warn Dumper(\@releases);
            @releases = grep { $_->{authorized} eq 'true' } @releases;
        }
        if(@releases > 1) {
            warn "Too many results for $req, removing devel releases\n";
#        warn Dumper(\@releases);
            @releases = grep { $_->{maturity} ne 'developer' } @releases;
        }
        if (@releases > 1) {
            warn "Still too many results for $req, giving up\n";
            warn Dumper \@releases;
#            next;
        }
        warn "No download! " . Dumper($req) if(!$releases[0]->{download_url});
        push @downloads, $releases[0]->{download_url};
    }

    if(@downloads != scalar(keys %{$reqs})) {
        print "Argh, didnt get the same number of downloads as original deps!\n";
    }

    print Dumper($module->distribution->prereq_pm);
    print Dumper(\@downloads);

    ## Last ditch:
    die "Couldn't find some of the downloads" if(grep {undef} @downloads);
    
    return \@downloads;
}


# my $packages = '/home/castaway/.cpanm/sources/http%search.cpan.org%CPAN/02packages.details.txt.gz';
# my @deps = CPAN::FindDependencies::finddeps('CPAN::FindDependencies', '02packages' => $packages);
# #print Dumper(\@deps);
# foreach my $dep (@dependencies) {
#     print ' ' x $dep->depth();
#     print $dep->name().' ('.$dep->distribution().")\n";
# }
