# Create a user agent object
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

my $rest_c = REST::Client->new();
$rest_c->setFollow(1);
# OPTIONAL LWP settings
my $rest_lwp = $rest_c->getUseragent();
sub dump { print STDERR Dumper shift->as_string; return};
$rest_lwp->add_handler("request_send",  \&dump);
$rest_lwp->add_handler("response_done",  \&dump);

sub run_overpass_query {
	my $query = shift;
    print "Calling overpass API for query\n$query\n";
	$rest_c->GET(
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
	my $json = decode_utf8($rest_c->responseContent);
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
	print Dumper $elems;
	return shift @$elems;
}
 
# Create a request
#use constant URL_RPDP_SEARCH_TMPL => 'https://www.rpdp.hostingasp.pl/RPDPWebService.asmx/GetTreesByGirth?_pageNo=%u&_pageLen=%u&_showDead=%u';
use constant URL_RPDP_SEARCH_TMPL => 'https://www.rpdp.hostingasp.pl/RPDPWebService.asmx/GetPLTrees?_what=2&_pageNo=%u&_pageLen=%u&_showDead=%u&_createdOnOrAfterDate=%s&_mode=4';
use constant URL_RPDP_TREE_TMPL => 'https://www.rpdp.hostingasp.pl/Trees/UI/TreeFormRO.aspx?tID=%u';

sub get_rpdp_trees {
	my ($x_days,$page_num, $page_size) = @_;

	my $req = HTTP::Request->new(GET => sprintf(URL_RPDP_SEARCH_TMPL,$page_num,$page_size,0,time2str('%Y-%m-%d',time-60*60*24*$x_days)));
	$req->content_type('application/x-www-form-urlencoded');
	$req->content('query=libwww-perl&mode=dist');
	 
	# Pass request to the user agent and get a response back
	my $res = $ua->request($req);
	 
	# Check the outcome of the response
	die $res->status_line, "\n" unless $res->is_success;
	
	my $dom = XML::LibXML->load_xml(string => $res->content);
	
	my @trees;
	foreach my $t ($dom->findnodes('//NewDataSet/Table')) {
	    my $name = $t->findvalue("Name") || '<brak>';
	    my $species_pl = $t->findvalue("Species");
	    my $age = $t->findvalue("Age");
	    my $circumference= $t->findvalue("Girth");
	    my $is_bush = $t->findvalue("Bush");
	    my $tid = $t->findvalue("TID");
	    my $lat= $t->findvalue("GPSLat");
	    my $lon = $t->findvalue("GPSLong");
		my $url = sprintf URL_RPDP_SEARCH_TMPL, $tid;
	
		push @trees, 
			{ tid => $tid,
			  name => $name,
			  species_pl => $species_pl,
			  age => $age,
			  circumference => $circumference,
			  lat => $lat,
			  lon => $lon
			  };
	}
	printf "Found %u more trees\n", scalar(@trees);
	return @trees;
}

use constant OSM_NEW_NODE_TMPL => '
<osm>
 <node changeset="12" lat="..." lon="...">
   <tag k="note" v="Just a node"/>
   ...
 </node>
</osm>
';

sub add_tree_to_OSM {
	# TODO
	# see https://wiki.openstreetmap.org/wiki/API_v0.6#Create:_PUT_.2Fapi.2F0.6.2F.5Bnode.7Cway.7Crelation.5D.2Fcreate
	my $t = shift;
	printf "Will add this one to OSM: %s\n", Dumper $t;
}


my @recent_trees;
my $page_num = 1;
do { @_=&get_rpdp_trees(30,$page_num++,10); push @recent_trees, @_;} while (@_);
#print "Id,Name,Species (PL),Age,Circumference,GPS Lat, GPS Lon\n";
foreach my $t (@recent_trees){
	#if(my $t2 = check_if_exists_in_osm(50.9875500, 20.6499600)){
	if(my $t2 = check_if_exists_in_osm($t->{lat},$t->{lon})){
		printf STDERR "Tree nearby %s in OSM! %s\n", Dumper($t), Dumper($t2);
		next;
	}
	&add_tree_to_OSM($t);
}
printf "All done!\n";
