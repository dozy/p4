#!/usr/bin/env perl

use strict;
use warnings;
use Carp;
use File::Slurp;
use JSON;
use POSIX;
use Fcntl;
use File::Temp qw/ tempdir /;
use Getopt::Std;
use Readonly;
use Data::Dumper;

our $VERSION = '0';

Readonly::Scalar my $FROM => 0;
Readonly::Scalar my $TO => 1;
Readonly::Scalar my $VLALWAYSLOG => 0;
Readonly::Scalar my $VLMIN => 1;
Readonly::Scalar my $VLMED => 2;
Readonly::Scalar my $VLMAX => 3;

my %opts;
getopts('xshv:o:r:t:', \%opts);

if($opts{h}) {
	die qq{viv.pl [-s] [-x] [-v <verbose_level>] [-o <logname>] <config.json>\n};
}

my $do_exec = $opts{x};
my $strict_status_checks = $opts{s};
my $logfile = $opts{o};
my $verbosity_level = $opts{v};
$verbosity_level = 1 unless defined $verbosity_level;
my $logger = mklogger($verbosity_level, $logfile, q[viv]);
$logger->($VLMIN, 'viv.pl version '.($VERSION||q(unknown_not_deployed)).', running as '.$0);
my $cfg_file_name = $ARGV[0];
$cfg_file_name ||= q[test_cfg.json];
my $raf_list = process_raf_list($opts{r});    # insert inline RAFILE nodes
my $tee_list = process_raf_list($opts{t});    # insert tee with branch to RAFILE
$tee_list ||= {};

my $s = read_file($cfg_file_name);

my $cfg = from_json($s);

###############################################
# insert any tees requested into the main graph
###############################################
process_tee_list($tee_list, $cfg);

my %all_nodes = (map { $_->{id} => $_ } @{$cfg->{nodes}});

my $edges = $cfg->{edges};

my %exec_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[EXEC]; } @{$cfg->{nodes}}));
my %filter_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[FILTER]; } @{$cfg->{nodes}}));
my %infile_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[INFILE]; } @{$cfg->{nodes}}));
my %outfile_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[OUTFILE]; } @{$cfg->{nodes}}));
my %rafile_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[RAFILE]; } @{$cfg->{nodes}}));

$logger->($VLMAX, "==================================\nEXEC nodes(0):\n==================================\n", Dumper(%exec_nodes), "\n");

# Initial pass through RAFILE and OUTFILE nodes to mark the downstream EXEC node dependencies on upstream EXEC nodes
my %deps = ();
for my $file_node (values %rafile_nodes, values %outfile_nodes) {
	my $current_to_edges = _get_to_edges($file_node->{id}, $edges);
	my $current_from_edges = _get_from_edges($file_node->{id}, $edges);

	# produce list of id values for exec nodes immediately downstream from this node
	my @downstream_nodes = ();
	for my $edge (@$current_from_edges) {
		my $to_id = (split q{:}, $edge->{to})[0];
		push @downstream_nodes, $to_id;
	}

	for my $edge (@$current_to_edges) {
		my $from_id = (split q{:}, $edge->{from})[0];
		@{$deps{$from_id}}{(@downstream_nodes)} = (1) x @downstream_nodes;
	}
}

# now use the deps hash to update nodes, adding dependants and incrementing wait_counters as appropriate
for my $from_id (keys %deps) {
	my $from_node = $exec_nodes{$from_id};	# only EXEC nodes should feed into RAFILE and OUTFILE nodes

	my @downstream_nodes = (keys %{$deps{$from_id}});
	$from_node->{dependants} = \@downstream_nodes;
	for my $to_id (@downstream_nodes) {
		$exec_nodes{$to_id}->{wait_counter}++;
	}
}

$logger->($VLMAX, "\n==================================\nEXEC nodes(post RAFILE processing):\n==================================\n", Dumper(%exec_nodes), "\n");

# For each edge:
#  If both "from" and "to" nodes are of type EXEC, data transfer will be done via a named pipe,
#  otherwise via file whose name is determined by the non-EXEC node's name attribute (communication
#  between two non-EXEC nodes is of questionable value and is currently considered an error).
for my $edge (@{$edges}) {
	my ($from_node, $from_id, $from_port) = _get_node_info($edge->{from}, \%all_nodes);
	my ($to_node, $to_id, $to_port) = _get_node_info($edge->{to}, \%all_nodes);
	my $data_xfer_name;

	if($from_node->{type} eq q[EXEC]) {
		if($to_node->{type} eq q[EXEC]) {
			$data_xfer_name = _create_fifo($edge->{from});
		}
		elsif(defined $to_node->{subtype} and $to_node->{subtype} eq q[DUMMY]) {
			$data_xfer_name = q[];
		}
		else {
			$data_xfer_name = $to_node->{name};
		}
	}
	else {
		if($to_node->{type} eq q[EXEC]) {
			$data_xfer_name = $from_node->{name};
		}
		else {
			croak q[Edges must start or terminate in an EXEC node; from: ], $from_node->{id}, q[, to: ], $to_node->{id};
		}
	}

	_update_node_data_xfer($from_node, $from_port, $data_xfer_name, $FROM);
	_update_node_data_xfer($to_node, $to_port, $data_xfer_name, $TO);
}

$logger->($VLMAX, "\n==================================\nEXEC nodes(post edges preprocessing):\n==================================\n", Dumper(%exec_nodes), "\n");

$logger->($VLMAX, "EXEC nodes(post EXEC nodes preprocessing): ", Dumper(%exec_nodes), "\n");
setpgrp; # create new processgroup so signals can be fired easily in suitable way later
# kick off any unblocked EXEC nodes, noting their details for later release of any dependants
$logger->($VLMED, qq[master process is $$\n]);
my %pid2id = ();
for my $node_id (keys %exec_nodes) {
	my $wait_counter = $exec_nodes{$node_id}->{wait_counter};
	$wait_counter ||= 0;
	if($wait_counter == 0 and not $exec_nodes{$node_id}->{pid}) { # green light - execute

		my $node = $exec_nodes{$node_id};
		if((my $pid=_fork_off($node, $do_exec))) {
			$node->{pid} = $pid;
			$pid2id{$pid} = $node_id;
		}
	}
}

# now wait for the children
$logger->($VLMIN, "\n=========\nWaiting for the children\n=========\n");
while((my $pid=wait) > 0) {
	my $status = $?;
	my $wifexited = WIFEXITED($status);
	my $wexitstatus = $wifexited ? WEXITSTATUS($status) : undef;
	my $wifsignaled = WIFSIGNALED($status);
	my $wtermsig = $wifsignaled ? WTERMSIG($status) : undef;
	my $wifstopped = WIFSTOPPED($status);
	my $wstopsig = $wifstopped ? WSTOPSIG($status) : undef;
	my $sticky_end = ($wexitstatus || $wtermsig || $wstopsig);

	my $completed_node_id=$pid2id{$pid};
	my $completed_node = $exec_nodes{$completed_node_id};
	$completed_node->{done} = 1;
	my $dependants_list = $completed_node->{dependants};

	if($strict_status_checks and $sticky_end) {
		# These messages need tidying up (and undef values detected)
		$logger->($VLMIN, sprintf(qq[\n**********************************************\nPreparing exit due to abnormal return from child %s (pid: %d), return_status: %#04X, wifexited: %#04X, wexitstatus: %d (%#04X)\n**********************************************\n], $completed_node->{id}, $pid, $status, $wifexited, $wexitstatus, $wexitstatus), "\n");
		$logger->($VLMIN, sprintf(q[Child %s (pid: %d), wifsignaled: %#04X, wtermsig: %s], $exec_nodes{$pid2id{$pid}}->{id}, $pid, $wifsignaled, ($wifsignaled? $wtermsig: q{NA})), "\n");
		$logger->($VLMIN, sprintf(q[Child %s (pid: %d), wifstopped: %#04X, wstopsig: %s], $exec_nodes{$pid2id{$pid}}->{id}, $pid, $wifstopped, ($wifstopped? $wstopsig: q{NA})), "\n");

		$SIG{'ALRM'} ||= sub {
			######################################################################
			# kill the children
			######################################################################
			local $SIG{'TERM'} = 'IGNORE';
			kill TERM => 0;

			$logger->($VLMIN, sprintf(qq[\n**********************************************\nExiting due to abnormal return from child %s (pid: %d), return_status: %#04X, wifexited: %#04X, wexitstatus: %d (%#04X)\n**********************************************\n], $completed_node->{id}, $pid, $status, $wifexited, $wexitstatus, $wexitstatus), "\n");
			$logger->($VLMIN, sprintf(q[Child %s (pid: %d), wifsignaled: %#04X, wtermsig: %s], $completed_node->{id}, $pid, $wifsignaled, ($wifsignaled? $wtermsig: q{NA})), "\n");
			$logger->($VLMIN, sprintf(q[Child %s (pid: %d), wifstopped: %#04X, wstopsig: %s], $completed_node->{id}, $pid, $wifstopped, ($wifstopped? $wstopsig: q{NA})), "\n");

			croak sprintf(qq[\n**********************************************\nExiting due to abnormal status return from child %s (pid: %d), return_status: %#04X, wifexited: %#04X, wexitstatus: %#04X\n**********************************************\n], $completed_node->{id}, $pid, $status, $wifexited, $wexitstatus), "\n";
		};
		alarm 5;
	}else{

		$logger->($VLMED, sprintf(q[Child %s (pid: %d), return_status: %#04X, wifexited: %d (%#04X), wexitstatus: %s], $completed_node->{id}, $pid, $status, $wifexited, $wexitstatus, $wexitstatus), "\n");
		$logger->($VLMED, sprintf(q[Child %s (pid: %d), wifsignaled: %#04X, wtermsig: %s], $completed_node->{id}, $pid, $wifsignaled, ($wifsignaled? $wtermsig: q{NA})), "\n");
		$logger->($VLMED, sprintf(q[Child %s (pid: %d), wifexited: %#04X, wexitstatus: %s], $completed_node->{id}, $pid, $wifexited, $wexitstatus), "\n");

		if($dependants_list and @$dependants_list) {
			for my $dep_node_id (@$dependants_list) {
				my $dependant_node = $exec_nodes{$dep_node_id};
				$logger->($VLMED, "\tFound dependant: $dep_node_id with wait_counter $dependant_node->{wait_counter}\n");
				$dependant_node->{wait_counter}--;
				if($dependant_node->{wait_counter} == 0) { # green light - execute
					if((my $pid=_fork_off($dependant_node, $do_exec))) {
						$dependant_node->{pid} = $pid;
						$pid2id{$pid} = $dep_node_id;
					}
				}
			}
		} else {
			$logger->($VLMED, q[No dependants for child ], $completed_node->{id}, q[, pid ], $pid, "\n");
		}
	}
}
&{$SIG{'ALRM'}||sub{}}(); # fire off bad exit if set

$logger->($VLMIN, "Done\n");

sub _get_node_info {
	my ($edge_id, $all_nodes) = @_;

	my ($id, $port);
	# slightly more concise regex usage might be good here
	if($edge_id =~ /^([^:]*):(.*)$/) {
		($id, $port) = ($1, $2);
	}
	else {
		$id = $edge_id;
	}
	my $node = $all_nodes{$id};

	return ($node, $id, $port);
}

sub _create_fifo {
	my ($basename) = @_;

	my $tmpdir = tempdir( CLEANUP => 1 );
	my $leaf = $basename . q[_out];
	my $output_name = join "/", ($tmpdir, $leaf);
	mkfifo($output_name, 0666) or croak "Failed to mkfifo $output_name: $@";

	return $output_name;
}

sub _update_node_data_xfer {
	my ($node, $port, $data_xfer_name, $edge_side) = @_;

	if($node->{type} eq q[EXEC] and $data_xfer_name ne q[]) {
		if(defined $port) {
			if(my($inout) = grep {$_} $port=~/_(IN|OUT)__\z/smx , $port=~/\A__(IN|OUT)_/smx ){ # if port has _{IN,OUT}_ {suf,pre}fix convention
				#ensure port is connected to in manner suggested by naming convention
				croak 'Node '.($node->{'id'})." port $port connected as ".($edge_side == $FROM?q("from"):q("to")) if (($inout eq q(OUT))^($edge_side == $FROM));
			} else {
				croak 'Node '.($node->{'id'})." has poorly described port $port (no _{IN,OUT}__ {suf,pre}fix)\n";
			}
			my $cmd = $node->{'cmd'};
			for my$cmd_part ( ref $cmd eq 'ARRAY' ? @{$cmd}[1..$#{$cmd}] : ($node->{'cmd'}) ){
				return if ($cmd_part =~ s/\Q$port\E/$data_xfer_name/smx);
			} #if link for port has not been made (port never defined, or already substituted, in node cmd) bail out
			croak 'Node '.($node->{'id'})." has no port $port";
		}
		else {
			my $node_edge_std = $edge_side == $FROM? q[STDOUT]: q[STDIN];
			if($node->{$node_edge_std}){
				croak "Cannot use $node_edge_std for node ".($node->{'id'}).' more than once';
				#TODO: allow multiple STDOUT with dup?
			}
			if(exists $node->{"use_$node_edge_std"}){
				croak 'Node '.($node->{'id'})." configured not to use $node_edge_std" unless $node->{"use_$node_edge_std"};
			}
			$node->{$node_edge_std} = $data_xfer_name;
		}
	}
	else {
		# do nothing
	}

	return;
}

sub _get_from_edges {
	my ($node_id, $edges) = @_;

	my @current_from_edges = ( grep { $_->{from} =~ /^$node_id:?/; } @{$edges} );

	return \@current_from_edges;
}

sub _get_to_edges {
	my ($node_id, $edges) = @_;

	my @current_to_edges = ( grep { $_->{to} =~ /^$node_id:?/; } @{$edges} );

	return \@current_to_edges;
}

sub _fork_off {
	my ($node, $do_exec) = @_;
	my $cmd = $node->{'cmd'};
	my @cmd = ($cmd);
	if ( ref $cmd eq 'ARRAY' ){
		@cmd = @{$cmd};
		$cmd = '[' . (join ',',@cmd)  . ']';
	}

	if(my $pid=fork) {     # parent - record the child's departure
		$logger->($VLMED, qq[*** Forked off pid $pid with cmd: $cmd\n]);

		return $pid;
	}
	elsif(defined $pid) { # child - note: one way or the other, we're not returning from here
		$logger->($VLMED, qq[Child $$ ; cmd: $cmd\n]);

		if($do_exec) {
			$0 .= q{ (pending }.$node->{'id'}.qq{: $cmd)}; #rename process so fork can be easily identified whilst open waits on fifo
			open STDERR, q(>), $node->{'id'}.q(.).$$.q(.err) or croak "Failed to reset STDERR, pid $$ with cmd: $cmd";
			select(STDERR);$|=1;
			print STDERR "Process $$ for cmd $cmd:\n";
			print STDERR ' fileno(STDERR,'.(fileno STDERR).")\n";
			if(not $node->{use_STDIN}) { $node->{'STDIN'} ||= '/dev/null'; }
			if($node->{'STDIN'}) {
				sysopen STDIN, $node->{'STDIN'}, O_RDONLY|O_NONBLOCK or croak "Failed to reset STDIN, pid $$ with cmd: $cmd\n$!";
				fcntl STDIN, F_SETFL, (fcntl STDIN,F_GETFL,0 or croak "fcntl F_GETFL fail $!")&~O_NONBLOCK or croak "fcntl F_SETFL fail $!" ;
			}
			print STDERR ' fileno(STDIN,'.(fileno STDIN).') reading from '.($node->{'STDIN'}?$node->{'STDIN'}:'stdin') ."\n";
			if(not $node->{use_STDOUT}) { $node->{'STDOUT'} ||= '/dev/null'; }
			if($node->{'STDOUT'}) {
				open STDOUT, q(>), $node->{'STDOUT'} or croak "Failed to reset STDOUT, pid $$ with cmd: $cmd";
			}
			print STDERR ' fileno(STDOUT,'.(fileno STDOUT).') writing to '.($node->{'STDOUT'}?$node->{'STDOUT'}:'stdout') ."\n";
			print STDERR ' select waiting on STDIN' ."\n";
			my$rin="";vec($rin,fileno(STDIN),1)=1; select($rin,undef,undef,undef);
			$logger->($VLMED, qq[Child $$ execing]);
			print STDERR " execing....\n";
			exec @cmd or croak qq[Failed to exec cmd: ], join " ", @cmd;
		}
		else {
			$logger->($VLMED, q[child exec not switched on], "\n");
			exit 0;
		}
	}else{
		$logger->($VLMED, qq[*** Failed to fork off with cmd: $cmd\n]);
		croak qq[Failed to fork off with cmd: $cmd\n];
	}
}

sub mklogger {
	my ($verbosity_level, $log, $label) = @_;
	my $logf;
	my @mnthnames = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );

	# $log can be an open file handle, a string (file name) or undef (log to STDERR)
	if(ref $log eq 'GLOB') {
		$logf = $log;
	}
	elsif($log) {	# sorry, log file named "0" is not allowed
		open $logf, ">$log" or croak q[Failed to open log file: ], $log;
	}
	else {
		$logf = *STDERR;
	}

	if($label) {
		$label = "($label) ";
	}
	else {
		$label = '';
	}

	my @hlt = localtime;
	unless($verbosity_level == 0) { printf $logf "*** %d-%s-%d %02d:%02d:%02d - %s%s (%d) ***\n", $hlt[3], $mnthnames[$hlt[4]], $hlt[5]+1900, (reverse((@hlt)[0..2])), "created logger", $label, $verbosity_level; }

	return sub {
		my ($ms_level, @ms) = @_;

		return if ($ms_level > $verbosity_level);

		my @lt = localtime;
		printf $logf "*** %d-%s-%d %02d:%02d:%02d (%d/%d) %s- %s ***\n", $lt[3], $mnthnames[$lt[4]], $lt[5]+1900, (reverse((localtime)[0..2])), $ms_level, $verbosity_level, $label, join("", @ms);

		return;
	}
}

sub process_raf_list {
	my ($rafs) = @_;
	my $raf_map;

	if($rafs) {
		$raf_map = { (map { (split '=', $_); } (split /;/, $rafs)) };
	}

	return $raf_map;
}

###################################################################################################################
# process tee_list, adding an EXEC (teepot) and an OUTFILE node and new edges to them from the specified node ports
#  Note: this will modify the master graph if $tee_list is defined and not empty. It is intended to be a debugging
#   utility
###################################################################################################################
sub process_tee_list {
	my ($tee_list, $cfg) = @_;

	unless(defined $tee_list) {
		return;
	}

	my %node_map = (map { $_->{id} => $_ } @{$cfg->{nodes}});  # effectively, a local copy of %all_nodes
	for my $outport (keys %{$tee_list}) {
		##################################################################################
		# confirm existence and validity of source port (e.g. that it is "of type output")
		##################################################################################
		my ($src_node_id, $port) = (split q[:], $outport);
		if(not $src_node_id) { croak q[source node id specified as empty string]; }
		if($port and $port !~ /OUT/) { croak q[source node port not specified as an output port (naming convention)]; }
		my $src_node = $node_map{$src_node_id};
		if(not defined $src_node
			or $src_node->{type} ne q[EXEC]
			or not defined $src_node->{cmd}
			or ($port and ref $src_node->{cmd} eq q[ARRAY] and grep { $_ =~ /$port/; } @{$src_node->{cmd}} < 1)
			or ($port and not ref $src_node->{cmd} and $src_node->{cmd} !~ /$port/)
		) {
			carp q[Invalid source node specified for tee_list: ], $src_node_id, q[ (], $outport, q[)];
			next;
		}

		############################################################################################################################
		# based on the existence of an edge in the master graph from the specified tee_list output:
		#    EXISTS => standard case, redirect the "to" attribute to the new tee_node, tee_node's non-file output takes the original
		#                "to" value of the retrieved edge, newly created edge links tee_node output to original downstream node
		#    not EXISTS => output was originally to stdout (implicit edge), tee_node's non-file output goes to stdout, newly-created
		#                    edge links source to tee_node 
		############################################################################################################################

		my ($tinput_edge) = grep { $_->{from} eq $outport} @{$cfg->{edges}};
		if(not defined $tinput_edge and $port) { carp q[output port specified in tee list, but absence of edge implies stdout: ], $outport; next; }

		#################
		# create tee node
		#################
		my $tee_stream_outport_name = (defined $tinput_edge)? q/__ORIG_OUT__/: q/-/; # name for the streamed output port of the new tee_node
#		my $tee_stream_to_stdout = (defined $tinput_edge)? 0: 1; # will the tee node be writing to stdout?
		my $tnid=get_node_id(\%node_map, q[TEE_NODE]);
		if(not defined $tnid) {
			carp q[Failed to create id for tee node for port ], $outport;
			next;
		}
#		my $tee_node = { id => $tnid, type => q[EXEC], use_STDIN => 1, use_STDOUT => $tee_stream_to_stdout, cmd => [ 'teepot', $tee_stream_outport_name, '__FILE_OUT__', ], };
		my $tee_node = { id => $tnid, type => q[EXEC], use_STDIN => q[JSON::XS::true], use_STDOUT => q[JSON::XS::true], cmd => [ 'tee', $tee_stream_outport_name, ], };

		#########################
		# create output file node
		#########################
		my $fnid=get_node_id(\%node_map, q[OF_NODE]);
		if(not defined $fnid) {
			carp q[Failed to create id for of node for output file ], $outport;
			next;
		}
		my $of_node = { id => $fnid, type => q[OUTFILE], name => $tee_list->{$outport}, };

		###########################################
		# connect the tee node and output file node
		###########################################
#		my $tfile_edge = { id => '___TFILE_EDGE___', from => "$tnid:__FILE_OUT__", to => $fnid };
		my $tfile_edge = { id => '___TFILE_EDGE___', from => "$tnid", to => $fnid };

		#########################################################################################
		# create the edge which will link the new tee+outfile subgraph to the master graph ($cfg)
		#########################################################################################
		my $tee_connect_edge = (defined $tinput_edge)? { id => '___TCONNECT_EDGE___', from => "$tnid:__ORIG_OUT__", to => $tinput_edge->{to} }: { id => '___TCONNECT_EDGE___', from => $outport, to => $tnid };

		###########################################################################################
		# everything looks valid, so modify the master graph (consider queuing these until the end)
		###########################################################################################
		push @{$cfg->{nodes}}, $tee_node, $of_node;
		$node_map{$tnid} = $tee_node;
		$node_map{$fnid} = $of_node;
		push @{$cfg->{edges}}, $tee_connect_edge, $tfile_edge;
		if(defined $tinput_edge) { $tinput_edge->{to} = $tnid }; # change to the master graph, so this change happens here
	}

	return;
}

###########################################################################
# get_node_id:
#  this should find an unused node id (unused in the set of nodes supplied)
#  returns: id if successful, undef otherwise
###########################################################################
sub get_node_id {
	my ($nodes, $label) = @_;
	my $i=0;

	$label ||= q[LABEL];
	for my $i (0..9999) {
		my $nid = sprintf "___%s_%04d___", $label, $i;
		if(not exists $nodes->{$nid}) {
			return $nid;
		}
	} 

	return;
}

