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

=item * Source -> RPDP

Sample tree added by the script: L<https://master.apis.dev.openstreetmap.org/node/4319597672> (DEV OSM server)

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

Set OSM_USER and OSM_PASSWD environment variables for authentication the calls to OSM

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
use constant APP_NAME => 'TreeHunter';
use constant APP_VERSION => 0.6;

my $overpass_client = REST::Client->new();
$overpass_client->setFollow(1);
# OPTIONAL LWP settings
my $overpass_ua = $overpass_client->getUseragent();
sub dump { print STDERR Dumper shift->as_string; return};
my $trace_http = 0;
my $debug = 0;

if ($trace_http){
	$overpass_ua->add_handler("request_send",  \&dump);
	$overpass_ua->add_handler("response_done",  \&dump);
	$ua->add_handler("request_send",  \&dump);
	$ua->add_handler("response_done",  \&dump);
}

sub run_overpass_query {
	my $query = shift;
    print "Calling overpass API for query\n$query\n" if $debug;
	$overpass_client->GET(
		# see https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances
		# for server links
		# main URL:
		# 'http://overpass-api.de/api/interpreter',
		# but this seems to be less used
		sprintf ('http://overpass.openstreetmap.fr/api/interpreter?data=%s', uri_escape(encode_utf8($query))),
		{
			#'Content-Type'=>'application/x-www-form-urlencoded',
			'accept' => '*/*',
			'Content-type' => 'application/json;charset=utf-8'
			#				#'Authorization' => sprintf 'Bearer %s', $token
			#					}
		}
	);
	my $json = decode_utf8($overpass_client->responseContent);
	my $elems = from_json($json)->{elements} || die "FAILED to run the overpass query\n";
	return $elems;
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
	print Dumper $elems if $debug;
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
	    my $species_pl = $t->findvalue("SpeciesPL");
	    my $species_en= $t->findvalue("SpeciesEN");
	    my $species_lat = $t->findvalue("SpeciesLat");
	    my $age = $t->findvalue("Age");
	    my $circumference= $t->findvalue("Girth");
	    my $height = $t->findvalue("Height");
	    my $is_bush = $t->findvalue("Bush");
	    my $tid = $t->findvalue("TID");
	    my $lat= $t->findvalue("GPSLat");
	    my $lon = $t->findvalue("GPSLong");
	    my $protected = $t->findvalue("IsProtected");
		my $place_str = $t->findvalue("Localization");
		my $url = sprintf URL_RPDP_TREE_TMPL, $tid;
	
		my $osm_tree = { 
			  website =>$url,
			  source => URL_RPDP_BASE,
			  name => $name,
			  age => $age,
			  circumference => $circumference,
			  height => $height,
			  lat => $lat,
			  lon => $lon,
			  'species' => $species_lat,
			  'species:pl' => $species_pl,
			  'species:en' => $species_en,
			  polish => ($place_str =~ /Polska/i)
			};
		
		foreach (keys(%$osm_tree)){
			delete $osm_tree->{$_} if (!defined $osm_tree->{$_} || $osm_tree->{$_} =~ /^(?:\s*|0)$/); 
		}
		
		push @trees, $osm_tree; 
	}
	printf "Found %u more trees\n", scalar(@trees);
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

use constant OSM_SERVER_URL => 'https://master.apis.dev.openstreetmap.org';
use constant OSM_NODE_URL_TMPL => 'https://master.apis.dev.openstreetmap.org/node/%u';
use constant TREEHUNTER_GIT_URL => 'https://github.com/rdktz/treehunter';

sub add_tree_to_OSM {
	my $t = shift;
	printf ("Will add this one to OSM: %s\n", Dumper $t) if $debug;
	my $tt = Template->new(INCLUDE_PATH => '.', POST_CHOMP => 1) || die $Template::ERROR, "\n";
	my $xml_tmpl  = OSM_NEW_CHANGESET_TMPL;
	my $req_xml;
	$tt->process(\$xml_tmpl, {
		app_name => APP_NAME,
		app_version => APP_VERSION,
		comment => "Adding tree based on RPDP site",
		description => &TREEHUNTER_GIT_URL,
		#hint => sprintf "Found an problem with the added tree? Log an issue in GitHub %s/issues" . TREEHUNTER_GIT_URL
		},
		\$req_xml
	)  || die $tt->error(), "\n";
	#print "------------------\n$req_xml\n\n";
	my $osm_client = REST::Client->new();
	$osm_client->setFollow(1);
	my $osm_ua = $osm_client->getUseragent();
	$osm_ua->add_handler("request_send",  \&dump) if $trace_http;
	$osm_ua->add_handler("response_done",  \&dump) if $trace_http;
	$osm_client->PUT(
		sprintf ('%s%s', OSM_SERVER_URL, '/api/0.6/changeset/create'),
		$req_xml,
		{
			'Content-Type'=>'application/x-www-form-urlencoded',
			'accept' => '*/*',
			'Authorization' => sprintf 'Basic %s', encode_base64(sprintf '%s:%s', $ENV{OSM_USER}, $ENV{OSM_PASSWD})
		}
	) or die "$!";
	die $osm_client->responseContent unless $osm_client->responseCode() eq '200';
	my $changeset = decode_utf8($osm_client->responseContent) || die "Cannot decode REST service reponse";
	my $req_xml;
	$xml_tmpl = OSM_NEW_NODE_TMPL;
	# 
	my $tags; 
	map { $tags->{$_} = $t->{$_} unless /^(lat|lon|tid|polish)$/} keys(%$t);
	# add some OSM specific tags
	$tags->{&OSM_TAG_KEY_DENOTATION} = OSM_TAG_VAL_NATURAL_MONUMENT;
	$tags->{&OSM_TAG_KEY_NATURAL} = OSM_TAG_VAL_TREE;
	$tt->process(\$xml_tmpl, {
			change_num => $changeset,
			lon => $t->{lon},
			lat => $t->{lat},
			tags => $tags
		},
		\$req_xml
	)  || die $tt->error(), "\n";
	print "------------------\n$req_xml\n\n" if $debug;
	$osm_client->PUT(
		sprintf ('%s%s', OSM_SERVER_URL, '/api/0.6/node/create'),
		encode_utf8($req_xml),
		{
			'Content-Type'=>'application/x-www-form-urlencoded',
			'accept' => '*/*',
			'Authorization' => sprintf 'Basic %s', encode_base64(sprintf '%s:%s', $ENV{OSM_USER}, $ENV{OSM_PASSWD})
		}
	)  or die "$!";

	die $osm_client->responseContent unless $osm_client->responseCode() eq '200';
	my $new_node_num = $osm_client->responseContent + 0;
	#printf STDERR Dumper  $osm_client->responseContent unless $new_node_num > 0;
	printf "Got new node num %u\n", $new_node_num if $debug;
	return $new_node_num;
}

die "Missing OSM credentials\n" unless $ENV{OSM_USER} && $ENV{OSM_PASSWD};
my @recent_trees;
my $page_num =1; 
my $page_size=25;
my $tree_num=0;
my @trees;
my $stat = {};
do { 
	@trees=&get_rpdp_trees(undef,$page_num,$page_size);
	printf "Processing page %u (page size is %u)\n", $page_num, $page_size;
	#print "Id,Name,Species (PL),Age,Circumference,GPS Lat, GPS Lon\n";
	foreach my $t (@trees){
		next unless $t->{name} && !($t->{name} =~ /^\s$/);
		if (!(defined $t->{lat} && $t->{lat} != 0 && defined $t->{lon} && $t->{lon} != 0 )){
			printf STDERR "Coords missing for tree %s (%u) .. SKIPPING\n", encode_utf8($t->{name} || 'unnamed'), $t->{tid};
			$stat->{SKIPPED_NO_COORDS}++;
			next;
		}
		if (!($t->{polish})){ #outside Poland
			printf STDERR "Ouside Poland - SKIPPING for now\n";
			$stat->{SKIPPED_OUTSIZE_POLAND}++;
			next;	
		}
		if(my $t2 = check_if_exists_in_osm($t->{lat},$t->{lon})){
			printf STDERR "Tree nearby %s in OSM! %s\n... SKIPPING\n", Dumper($t), Dumper($t2);
			$stat->{SKIPPED_EXISTS}++;
			next;
		}
		my $node_num = &add_tree_to_OSM($t);
		printf "New oSM node link: %s referencing RPDP tree %s\n", 
			sprintf(OSM_NODE_URL_TMPL, $node_num),
			sprintf URL_RPDP_TREE_TMPL, $t->{website};
		$stat->{ADDED_TO_OSM}++;
	}
	$page_num++;
} while (@trees);
printf "All done!\nStats:\n%s", Dumper $stat;
