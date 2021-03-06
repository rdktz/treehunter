#!/usr/bin/perl
=head1 TreeHunter - a script to replicate Polish Monumental Tree Registry to OSM 

=head2 Tags

The data is replicated thanks to the cordiality of L<https://www.rpdp.hostingasp.pl/>.

The following OSM page lists the supported tags L<https://wiki.openstreetmap.org/wiki/Tag:natural=tree>
Currently the script uses only a subset of those, namely:

=over 4

=item * Age

=item * Height

=item * Species:PL

=item * Procted -> yes/no

=item * Name

=item * Source -> RPDP main site link as suggested in https://forum.openstreetmap.org/viewtopic.php?id=70465

Sample tree added by the script: L<https://master.apis.dev.openstreetmap.org/node/4324532379> (DEV OSM server)

=item * Website -> RPDP link

=back

=head2 APIs used

OSM APIs:

=over 4

=item * changeset

=item * node create

=back

See L<https://wiki.openstreetmap.org/wiki/API_v0.6#Create:_PUT_.2Fapi.2F0.6.2F.5Bnode.7Cway.7Crelation.5D.2Fcreate> for more info

Additionally L<Overpass search API|https://wiki.openstreetmap.org/wiki/Overpass_API> is used to check for duplicates.

=head2 Running

Supported command line options:

=over 4

=item * osm_user

=item * osm_pass

=item * debug

=item * http_trace

=item * skip_first X entries that would otherwise be added

=item * quit_after adding X new OSM trees

=item * instance - PROD/DEV (default is DEV)

=back

Examples:

$ ./treehunter.pl --osm_user=az.zdzi@yahoo.com --osm_pass *** --instance=DEV

$ ./treehunter.pl --osm_user=az.zdzi@yahoo.com --osm_pass *** --instance=DEV --debug --http_trace --quit_after 1  \
	> 1>treehunter_`date +"%F_%H.%M.%S"`.out.txt 2>treehunter_`date +"%F_%H.%M.%S"`.err.txt


=head2 Bugs and Help

Bugs can be reported via GitHub L<https://github.com/rdktz/treehunter/issues>

Readme generated with L<https://metacpan.org/pod/distribution/Pod-Markdown/bin/pod2markdown>

=cut

# Create a user agent object
use strict;
use LWP::UserAgent;
use XML::LibXML;
use Data::Dumper;
use Date::Parse;
use Date::Format; # -e "print time2str('%c',str2time('9-03-2012 11:26:00 CET')-1526,'CET');"
use POSIX 'ceil';
my $ua = LWP::UserAgent->new;
$ua->agent("treehunter/0.1 ");
use utf8;
binmode(STDOUT, ":utf8");
use REST::Client;
use Encode;
use URI::Escape;
use JSON;
use JSON::Parse;
use Template;
use MIME::Base64;
use String::Util qw(trim);
my ($opt_osm_user, $opt_osm_pass, $opt_instance, $opt_max_new, $opt_debug, $opt_http_trace, $opt_skip_first, $opt_quit_after);
use Getopt::Long qw( GetOptions );
GetOptions( 
	"osm_user=s" => \$opt_osm_user,
	"osm_pass=s", => \$opt_osm_pass, 
	"instance=s", => \$opt_instance,
	"max_new=i" => \$opt_max_new,
	"skip_first=i" => \$opt_skip_first, # skip first X OSM tree additions
	"quit_after=i" => \$opt_quit_after,  # quit after X'th OSM tree addition
	"debug" => \$opt_debug,
	"http_trace"=> \$opt_http_trace
);

use constant APP_NAME => 'TreeHunter';
use constant APP_VERSION => 0.8;

# BASIC APP CONFIG
use constant OSM_SERVER_URL_DEV=> 'https://master.apis.dev.openstreetmap.org';
use constant OSM_SERVER_URL_PROD => 'https://api.openstreetmap.org' ;
open(my $log, '> :encoding(UTF-8)', sprintf ('treehunter_%s.log.txt', time2str('%Y%m%d%H%M%S',time))); 
my $osm_server_url;
if ($opt_instance =~ /PROD/){
		printf "Are you sure this should be run against PROD OSM instance?! If so, please type 'PROD':\n";
		my $conf = <>;
		die "PROD unconfirmed" unless $conf =~ /^PROD$/;
		$osm_server_url = OSM_SERVER_URL_PROD;
		printf $log "Using the PROD istnance\n";
} else {
	printf $log "Using the DEV istnance\n";
	printf "Using the DEV istnance\n";
	$osm_server_url = OSM_SERVER_URL_DEV;
}
die "Missing user or password for OSM API" unless $opt_osm_user && $opt_osm_pass;

# OPTIONAL LWP settings
my $overpass_client = REST::Client->new();
$overpass_client->setFollow(1);
my $overpass_ua = $overpass_client->getUseragent();
# TODO: check why printf doesn't work here. Is this linked to some cygwin specific locking?
sub dump { print $log Dumper(shift->as_string); return};
my $tt = Template->new(INCLUDE_PATH => '.', POST_CHOMP => 1) || die $Template::ERROR, "\n";
my $osm_client = REST::Client->new();
$osm_client->setFollow(1);
my $osm_ua = $osm_client->getUseragent();
$osm_ua->add_handler("request_send",  \&dump) if $opt_http_trace;
$osm_ua->add_handler("response_done",  \&dump) if $opt_http_trace;

if ($opt_http_trace){
	$overpass_ua->add_handler("request_send",  \&dump);
	$overpass_ua->add_handler("response_done",  \&dump);
	$ua->add_handler("request_send",  \&dump);
	$ua->add_handler("response_done",  \&dump);
}

### END config
#

#use contract DEFAULT_OSM_SERVER => 'http://overpass.openstreetmap.fr';
use constant DEFAULT_OSM_SERVER => 'http://lz4.overpass-api.de';
use constant OSM_STATUS_RETRIES => 10;
use constant OSM_QUERY_RETRY_SECS => 10; # this should not really happen with the status check for free slots but it does happen
use constant OSM_QUERY_RETRIES => 5;

sub run_overpass_query {
	my $query = shift;
	my $i=0;
	while ($i++ < OSM_STATUS_RETRIES) {
		my $delay = &time_till_free_slot;
		last unless $delay; # need to wait a few secs?
		my $msg = sprintf "No free Overpass API slots.. sleeping for %u seconds\n", $delay;
		printf $log $msg;
		printf STDERR $msg;
		sleep $delay;
	}
	
    printf $log "Calling overpass API for query\n$query\n" if $opt_debug;
	my $osm_server = $ENV{OSM_SERVER} || DEFAULT_OSM_SERVER;
	$i=0;
	while ( $i++ < OSM_QUERY_RETRIES) {
		$overpass_client->GET(
			# see https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances
			# for server links
			# main URL:
			# 'http://overpass-api.de/api/interpreter',
			# but this seems to be less used
			sprintf ('%s/api/interpreter?data=%s', $osm_server, uri_escape(encode_utf8($query))),
			{
				#'Content-Type'=>'application/x-www-form-urlencoded',
				'accept' => '*/*',
				'Content-type' => 'application/json;charset=utf-8'
				#				#'Authorization' => sprintf 'Bearer %s', $token
				#					}
			}
		);
		my $code = $overpass_client->responseCode;
		my $err_msg = sprintf "Overpass query failed with status %u. Going to retry..\n", $code;
		if ($code==200){
			last;
		} else {
			printf $log $err_msg;
			printf STDERR $err_msg;
			if (OSM_QUERY_RETRIES <= $i) {
				printf STDERR $overpass_client->responseContent;
				die "Couldn't execute the query despite multiple retries";
			}
			sleep OSM_QUERY_RETRY_SECS;
		}
	} 
	my $json = decode_utf8($overpass_client->responseContent);
	my $elems = from_json($json)->{elements} || die "FAILED to run the overpass query\n";
	return $elems;
}

#
#	sample response when slots are available
#
#	Connected as: 1394412879
#	Current time: 2020-11-18T13:19:13Z
#	Rate limit: 2
#	1 slots available now.
#	Slot available after: 2020-11-18T13:19:18Z, in 5 seconds.
#	Currently running queries (pid, space limit, time limit, start time):
#
#	sample response when slots are NOT available
#
#	Connected as: 1394412879
#	Current time: 2020-11-18T13:19:10Z
#	Rate limit: 2
#	Slot available after: 2020-11-18T13:19:11Z, in 1 seconds.
#	Slot available after: 2020-11-18T13:19:18Z, in 8 seconds.
#	Currently running queries (pid, space limit, time limit, start time):
#
# 	REFERENCES: 
# 		https://github.com/drolbr/Overpass-API/issues/580
#	
#	TODO: we should ideally check all slots but it seems they are storted ascending by time-to-go 
#
sub time_till_free_slot {
    printf $log "Calling overpass API status end-point" if $opt_debug;
	my $osm_server = $ENV{OSM_SERVER} || DEFAULT_OSM_SERVER;
	$overpass_client->GET(
		sprintf ('%s/api/status', $osm_server),
		{
			#'Content-Type'=>'application/x-www-form-urlencoded',
			'accept' => '*/*',
			'Content-type' => 'application/json;charset=utf-8'
			#				#'Authorization' => sprintf 'Bearer %s', $token
			#					}
		}
	);
	my $txt= decode_utf8($overpass_client->responseContent);
	if ($txt =~ m/(\d+) slots available now/i){
		return 0;
	}
	$txt =~ m/Slot available after.*in\s+(\d+)\s+seconds/i;
	return $1;
}

use constant OSM_QUERY_TREES_NEARBY_TMPL => '
	[out:json][timeout:60];
	node["natural"="tree"](around:%u,%f,%f);
	out body;
';

use constant OSM_NEAR_RADIUS => 100; # meters
sub check_if_exists_in_osm {
	my ($lat,$lon,$radius) = @_;
	my $elems = &run_overpass_query(sprintf OSM_QUERY_TREES_NEARBY_TMPL,OSM_NEAR_RADIUS,$lat,$lon);
	printf $log Dumper( $elems) if $opt_debug;
	return shift @$elems;
}
 
# Create a request
# sample request
# 	https://www.rpdp.hostingasp.pl/RPDPWebService.asmx/GetPLTrees?_what=2&_pageNo=1&_pageLen=10&_showDead=0&_createdOnOrAfterDate=2020-03-01&_mode=4
use constant URL_RPDP_SEARCH_TMPL => 'https://www.rpdp.hostingasp.pl/RPDPWebService.asmx/GetPLTrees?_what=2&_pageNo=%u&_pageLen=%u&_showDead=%u&_createdOnOrAfterDate=%s&_mode=4';
use constant URL_RPDP_TREE_TMPL => 'https://www.rpdp.hostingasp.pl/Trees/UI/TreeFormRO.aspx?tID=%u';
use constant URL_RPDP_BASE => 'https://www.rpdp.hostingasp.pl';

sub get_rpdp_trees {
	my ($x_days,$page_num, $page_size) = @_;
	my $date_str = $x_days?time2str('%Y-%m-%d',time-60*60*24*$x_days):'';
	my $req = HTTP::Request->new(GET => sprintf(URL_RPDP_SEARCH_TMPL,$page_num,$page_size,0,$date_str));
	$req->content_type('application/x-www-form-urlencoded');
	$req->content('query=libwww-perl&mode=dist');
	 
	# Pass request to the user agent and get a response back
	my $res = $ua->request($req);
	 
	# Check the outcome of the response
	die $res->status_line, "\n" unless $res->is_success;
	
	my $dom = XML::LibXML->load_xml(string => $res->content);
	
	my @trees;
	foreach my $t ($dom->findnodes('//NewDataSet/Table')) {
	    my $name = $t->findvalue("Name"); 
		$name =~ s/"//g;
		if ($name=~ /aleja|,/i){
			#something fishy about the name - probably this does not describe one tree well
			printf $log "Removed suspicious tree name '%s'\n", $name;
			$name= undef;
		}
	    my $species_pl = $t->findvalue("SpeciesPL");
	    my $species_en= $t->findvalue("SpeciesEN");
	    my $species_lat = $t->findvalue("SpeciesLat");
	    my $age = $t->findvalue("Age");
		my $start_date;
		if ($age) {
			$start_date = time2str('%Y',time) - $age;
			$start_date = sprintf('~%s', $start_date - $start_date % 10), # round the date and add tilde for the approx planted date
		};
	    my $circumference= $t->findvalue("Girth");
	    my $height = $t->findvalue("Height");
	    my $is_bush = $t->findvalue("Bush");
	    my $tid = $t->findvalue("TID");
	    my $lat= $t->findvalue("GPSLat");
	    my $lon = $t->findvalue("GPSLong");
	    my $protected = $t->findvalue("IsProtected");
		my $class = trim($t->findvalue("Class"));

	
		my $place_str = $t->findvalue("Localization");
		$place_str =~ m/Polska, ([^,]+)/;
		my $pl_voivodship = $1;
		my $url = sprintf URL_RPDP_TREE_TMPL, $tid;
		my $poor_gps = $t->findvalue("GPSInaccurate") || $t->findvalue("GPSVeryInaccurate");
		my $osm_tree = { 
			  website =>$url,
			  # source => URL_RPDP_BASE,		# source:website instead
			  name => $name,
			  # age => $age,  # use start_date as suggested in https://forum.openstreetmap.org/viewtopic.php?id=70465
			  circumference => $circumference,
			  height => $height,
			  lat => $lat,
			  lon => $lon,
			  'species' => $species_lat,
			  'species:pl' => $species_pl,
			  'species:en' => $species_en,
			  poor_gps => $poor_gps,
			  protected => $protected ? 'yes' : 'no', # use protected instead of 'monument' - see https://forum.openstreetmap.org/viewtopic.php?id=70465
			  custom_class => $class,
			  start_date => $start_date,
			  pl_voivodship => $pl_voivodship,
			  'ref:rpdz' => $tid
			};
		
		foreach (keys(%$osm_tree)){
			delete $osm_tree->{$_} if (!defined $osm_tree->{$_} || $osm_tree->{$_} =~ /^(?:\s*|0)$/); 
		}
		
		push @trees, $osm_tree; 
	}
	printf $log "Found %u more trees\n", scalar(@trees);
	return @trees;
}

use constant OSM_NEW_CHANGESET_TMPL => '
<osm>
	<changeset version="0.6" generator="[% app_name %]">
		<tag k="created_by" v="[% app_name %] [% app_version %]"/>
		<tag k="description" v="[% description %]"/>
		<tag k="comment" v="[% comment %]"/>
	</changeset>
</osm>
';


use constant OSM_NEW_NODE_TMPL => '
<osm>
 <node changeset="[% change_num %]" lon="[% lon %]" lat="[% lat %]">
   [% FOREACH tag IN tags %]
   	<tag k="[% tag.key %]" v="[% tag.value %]"/>
   [% END %]
 </node>
</osm>
';

# see https://wiki.openstreetmap.org/wiki/Tag:natural=tree for the list of tags
use constant OSM_TAG_KEY_DENOTATION => 'denotation';
use constant OSM_TAG_VAL_NATURAL_MONUMENT=> 'natural_monument';
use constant OSM_TAG_KEY_NATURAL=> 'natural';
use constant OSM_TAG_VAL_TREE => 'tree';
use constant OSM_TAG_KEY_SOURCE_SITE => 'source:website';
use constant OSM_TAG_KEY_SOURCE_DATE => 'source:date';

use constant OSM_NODE_URL_TMPL => 'https://master.apis.dev.openstreetmap.org/node/%u';
use constant TREEHUNTER_GIT_URL => 'https://github.com/rdktz/treehunter';

my $changesets = {}; # each changeset can accomodate up to 10k changes 
					# splitting as suggested in https://forum.openstreetmap.org/viewtopic.php?id=70465
sub get_OSM_change_set {
	my $scope = shift; # this will be the voivodhship effectively
	my $changeset = $changesets->{$scope};
	return $changeset if defined $changeset;
	my $xml_tmpl  = OSM_NEW_CHANGESET_TMPL;
	my $req_xml;
	$tt->process(\$xml_tmpl, {
		app_name => APP_NAME,
		app_version => APP_VERSION,
		comment => sprintf("Adding trees based on RPDP site (scope = '%s')", $scope),
		description => &TREEHUNTER_GIT_URL,
		#hint => sprintf "Found an problem with the added tree? Log an issue in GitHub %s/issues" . TREEHUNTER_GIT_URL
		},
		\$req_xml
	)  || die $tt->error(), "\n";
	#print "------------------\n$req_xml\n\n";
	$osm_client->PUT(
		sprintf ('%s%s', $osm_server_url, '/api/0.6/changeset/create'),
		encode_utf8($req_xml),
		{
			'Content-Type'=>'application/x-www-form-urlencoded',
			'accept' => '*/*',
			'Authorization' => sprintf 'Basic %s', encode_base64(sprintf '%s:%s', $opt_osm_user, $opt_osm_pass)
		}
	) or die "$!";
	die $osm_client->responseContent unless $osm_client->responseCode() eq '200';
	my $changeset = decode_utf8($osm_client->responseContent) || die "Cannot decode REST service reponse";
	die "Wrong changeset number unless " unless $changeset > 1;
	printf $log "Storing changeset %u for scope '%s'\n", $changeset, $scope;
	$changesets->{$scope} = $changeset;
	return $changeset;
}

sub add_tree_to_OSM {
	my $t = shift;
	my $changeset = shift;
	printf $log ("Will add this one to OSM: %s\n", Dumper $t) if $opt_debug;
	my $req_xml;
	my $xml_tmpl = OSM_NEW_NODE_TMPL;
	#  filter the tags and leave only OSM tree standard - see https://wiki.openstreetmap.org/wiki/Tag:natural=tree
	my $tags; 
	map { $tags->{$_} = $t->{$_} unless /^(lat|lon|tid|pl_voivodship|custom_class)$/} keys(%$t);
	# add some OSM specific tags
	$tags->{&OSM_TAG_KEY_DENOTATION} = OSM_TAG_VAL_NATURAL_MONUMENT;
	$tags->{&OSM_TAG_KEY_NATURAL} = OSM_TAG_VAL_TREE;
	$tags->{&OSM_TAG_KEY_SOURCE_SITE} = URL_RPDP_BASE ;
	#$tags->{&OSM_TAG_KEY_SOURCE_DATE} = time2str('%Y',time); # not really convinced this is useful
	
	$tt->process(\$xml_tmpl, {
			change_num => $changeset,
			lon => $t->{lon},
			lat => $t->{lat},
			tags => $tags
		},
		\$req_xml
	)  || die $tt->error(), "\n";
	printf $log "------------------\n$req_xml\n\n" if $opt_debug;
	$osm_client->PUT(
		sprintf ('%s%s', $osm_server_url, '/api/0.6/node/create'),
		encode_utf8($req_xml),
		{
			'Content-Type'=>'application/x-www-form-urlencoded',
			'accept' => '*/*',
			'Authorization' => sprintf 'Basic %s', encode_base64(sprintf '%s:%s', $opt_osm_user, $opt_osm_pass)
		}
	)  or die "$!";

	die $osm_client->responseContent unless $osm_client->responseCode() eq '200';
	my $new_node_num = $osm_client->responseContent + 0;
	#printf $log STDERR Dumper  $osm_client->responseContent unless $new_node_num > 0;
	printf $log "Got new node num %u\n", $new_node_num if $opt_debug;
	return $new_node_num;
}

my $stat = {};
sub process {
	my @recent_trees;
	my $page_num =1; 
	my $page_size=25;
	my $tree_num=0;
	my @trees;
	do {
		@trees=&get_rpdp_trees(undef,$page_num,$page_size);
		printf $log "Processing page %u (page size is %u)\n", $page_num, $page_size;
		#print "Id,Name,Species (PL),Age,Circumference,GPS Lat, GPS Lon\n";
		foreach my $t (@trees){
			if ($opt_quit_after && $stat->{ADDED_TO_OSM} >= $opt_quit_after) {
				return;
			}
			if ($opt_max_new && $stat->{ADDED_TO_OSM} >= $opt_max_new){
				printf $log "Forcing quick after %u of new records\n", $opt_max_new;
				exit 0;
			}
			if (!(defined $t->{lat} && $t->{lat} != 0 && defined $t->{lon} && $t->{lon} != 0 )){
				printf $log "Coords missing for tree %s (%u) .. SKIPPING\n", encode_utf8($t->{name} || 'unnamed'), $t->{tid};
				$stat->{SKIPPED_NO_COORDS}++;
				next;
			}
			if ($t->{poor_gps}){
				printf $log  "Poor GPS coords %s\n... SKIPPING\n", Dumper($t);
				$stat->{SKIPPED_POOR_GPS}++;
				next;
			}
			if (!($t->{pl_voivodship})){ #outside Poland
				printf TDERR "Ouside Poland - SKIPPING for now\n";
				$stat->{SKIPPED_OUTSIZE_POLAND}++;
				next;	
			}
			if (!($t->{protected} =~ /yes/) && !($t->{custom_class} =~ /^(A|B)$/ )){
				printf $log  "Class < B and not protected by law %s\n", Dumper($t);
				$stat->{SKIPPED_LOW_CLASS_NOT_PROTECTED}++;
				next;
			}
			if(my $t2 = check_if_exists_in_osm($t->{lat},$t->{lon})){
				printf $log  "Tree nearby %s in OSM! %s\n... SKIPPING\n", Dumper($t), Dumper($t2);
				$stat->{SKIPPED_EXISTS}++;
				next;
			}
			if ($opt_skip_first && $stat->{SKIPPED_FIRST_X} < $opt_skip_first) {
				printf $log  "SKIPPING first X trees inlcluding %s\n", Dumper($t);
				$stat->{SKIPPED_FIRST_X}++;
				next;
			}
			my $node_num = &add_tree_to_OSM($t, &get_OSM_change_set($t->{pl_voivodship}));
			printf $log "New oSM node link: %s referencing RPDP tree %s\n", 
				sprintf(OSM_NODE_URL_TMPL, $node_num),
				sprintf URL_RPDP_TREE_TMPL, $t->{website};
			$stat->{ADDED_TO_OSM}++;
		}
		$page_num++;
		$tree_num+=scalar @trees;
		printf $log "Current stats:\n%s", Dumper $stat;
		if (ceil($tree_num/100) != ceil(($tree_num - scalar(@trees)) / 100)) {
			printf STDERR "Processed %u trees from RPDP\n", $tree_num;
		}
	} while (@trees);
}

&process;
printf $log "All done!\nFinal stats:\n%s", Dumper $stat;
printf "All done!\nFinal stats:\n%s", Dumper $stat;
