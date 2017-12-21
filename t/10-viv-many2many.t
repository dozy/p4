use strict;
use warnings;
use Carp;
use Test::More tests => 2;
use Test::Cmd;
use Perl6::Slurp;
use JSON;
use File::Temp qw(tempdir);
use Cwd;

my $tdir = tempdir(CLEANUP => 1);
my $odir=getcwd();

my $graph_file = $tdir . q[/input.json];
my $infile = q[indata.txt];
my $outfile = q[mainout.txt];

my $graph = {
	description =>	'minimal failing test pipeline. Fails because of many-to-many edge combination',
	version => '2.0',
	nodes => [
	{	id => 'hello',
		type => 'EXEC',
		use_STDIN => JSON::false,
		use_STDOUT => JSON::true,
		cmd => 'echo hello'
	},
	{	id => 'goodbye',
		type => 'EXEC',
		use_STDIN => JSON::false,
		use_STDOUT => JSON::true,
		cmd => 'echo bye'
	},
	{	id => 'rev',
		type => 'EXEC',
		use_STDIN => JSON::true,
		use_STDOUT => JSON::true,
		cmd => ['rev']
	},
	{	id => 'cap',
		type => 'EXEC',
		use_STDIN => JSON::true,
		use_STDOUT => JSON::true,
		cmd => ['tr', '[:lower:]', '[:upper:]']
	},
	],
	edges => [
	],
};

subtest 'test many2man failure' => sub {
    plan tests => 9;

    my @failure_orders = (
      {
        errms => 'ERROR: processing edge from goodbye:__stdout__ to rev:__stdin__: illegal many:many creation, alternate input source(s) hello:__stdout__ to rev:__stdin__',
	edges => [
          {id => 'e0', from => 'hello', to => 'rev'},
          {id => 'e1', from => 'goodbye', to => 'cap'},
          {id => 'e2', from => 'goodbye', to => 'rev'},
        ],
      },
      {
        errms => 'ERROR: processing edge from goodbye:__stdout__ to cap:__stdin__: illegal many:many creation, alternate input source(s) hello:__stdout__;goodbye:__stdout__ to cap:__stdin__',
	edges => [
          {id => 'e0', from => 'hello', to => 'rev'},
          {id => 'e2', from => 'goodbye', to => 'rev'},
          {id => 'e1', from => 'goodbye', to => 'cap'},
        ],
      },
      {
        errms => 'ERROR: processing edge from goodbye:__stdout__ to cap:__stdin__: illegal many:many creation, alternate input source(s) goodbye:__stdout__ to cap:__stdin__',
	edges => [
          {id => 'e2', from => 'goodbye', to => 'rev'},
          {id => 'e1', from => 'goodbye', to => 'cap'},
          {id => 'e0', from => 'hello', to => 'rev'},
        ],
      },
    );

    for my $fo (@failure_orders) {
      $graph->{edges} = $fo->{edges};

      # create input JSON for subtest
      my $test = Test::Cmd->new( prog => $odir.'/bin/viv.pl', workdir => q());
      ok($test, 'made test object');
      my $graph_json = to_json($graph) or croak q[Failed to produce JSON test graph];
      $test->write($graph_file, $graph_json);
      if($? != 0) { croak qq[Failed to create test input graph file $graph_file, exit_status: $?]; }

      my $exit_status = $test->run(chdir => $test->curdir, args => "$graph_file");
      ok($exit_status>>8 == 255, "exit value for failing test");

      like($test->stderr,qr(\Q$fo->{errms}\E)smx, "expected err info");
    }
};

# this condition only generates warnings in pre-version 2 templates
subtest 'test many2man failure (v1)' => sub {
    plan tests => 9;

    my @failure_orders = (
      {
        errms => 'WARNING: processing edge from goodbye:__stdout__ to rev:__stdin__: illegal many:many creation, alternate input source(s) hello:__stdout__ to rev:__stdin__',
	edges => [
          {id => 'e0', from => 'hello', to => 'rev'},
          {id => 'e1', from => 'goodbye', to => 'cap'},
          {id => 'e2', from => 'goodbye', to => 'rev'},
        ],
      },
      {
        errms => 'WARNING: processing edge from goodbye:__stdout__ to cap:__stdin__: illegal many:many creation, alternate input source(s) hello:__stdout__;goodbye:__stdout__ to cap:__stdin__',
	edges => [
          {id => 'e0', from => 'hello', to => 'rev'},
          {id => 'e2', from => 'goodbye', to => 'rev'},
          {id => 'e1', from => 'goodbye', to => 'cap'},
        ],
      },
      {
        errms => 'WARNING: processing edge from goodbye:__stdout__ to cap:__stdin__: illegal many:many creation, alternate input source(s) goodbye:__stdout__ to cap:__stdin__',
	edges => [
          {id => 'e2', from => 'goodbye', to => 'rev'},
          {id => 'e1', from => 'goodbye', to => 'cap'},
          {id => 'e0', from => 'hello', to => 'rev'},
        ],
      },
    );

    $graph->{version} = '1.0';
    for my $fo (@failure_orders) {
      $graph->{edges} = $fo->{edges};

      # create input JSON for subtest
      my $test = Test::Cmd->new( prog => $odir.'/bin/viv.pl', workdir => q());
      ok($test, 'made test object');
      my $graph_json = to_json($graph) or croak q[Failed to produce JSON test graph];
      $test->write($graph_file, $graph_json);
      if($? != 0) { croak qq[Failed to create test input graph file $graph_file, exit_status: $?]; }

      my $exit_status = $test->run(chdir => $test->curdir, args => "$graph_file");
      ok($exit_status>>8 == 0, "exit value for warning test");

      like($test->stderr,qr(\Q$fo->{errms}\E)smx, "expected err info");
    }
};

1;
