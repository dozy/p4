use strict;
use warnings;
use Test::More tests => 2;
use Test::Deep;
use Perl6::Slurp;
use Data::Dumper;
use JSON;

my $template = q[t/data/10-vtfp-00.json];

{
my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -keys p3 -vals break $template |");
my $c = {edges=> [], nodes => [ {cmd => [q~/bin/echo~,q~one~,q~break~], type => q~EXEC~, id => q~n1~}]};
cmp_deeply ($vtfp_results, $c, 'correct vtfp results');
}

{
my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -keys p1,p2 -vals first,second $template |");
my $c = {edges => [], nodes => [ {cmd => [q~/bin/echo~,q~first~,q~second~], type => q~EXEC~, id => q~n1~}]};
cmp_deeply ($vtfp_results, $c, 'second correct vtfp results');
}

