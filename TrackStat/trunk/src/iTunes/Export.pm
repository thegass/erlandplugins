#         TrackStat::iTunes module
# 				TrackStat plugin 
#
#    Copyright (c) 2006 Erland Isaksson (erland_i@hotmail.com)
#
#    Portions of code derived from the iTunesUpdate 1.7.2 plugin
#    Copyright (c) 2004-2006 James Craig (james.craig@london.com)
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA


use strict;
use warnings;
                   
package Plugins::TrackStat::iTunes::Export;

use Date::Parse qw(str2time);
use Fcntl ':flock'; # import LOCK_* constants
use POSIX qw(strftime);
use File::Spec::Functions qw(:ALL);
use File::Basename;
use DBI qw(:sql_types);
use Plugins::TrackStat::Plugin;
use Plugins::TrackStat::Storage;
use Slim::Utils::Misc;


sub getCustomScanFunctions {
	my %functions = (
		'id' => 'itunesexport',
		'order' => '75',
		'defaultenabled' => 0,
		'name' => 'iTunes Statistics Export',
		'description' => "This module exports statistic information in SlimServer to iTunes. The information exported are ratings, playcounts, last played time and added time.<br><br>Information is exported from TrackStat to an export file which will be placed in the specified output directory. Note that the generated iTunes history file must be run with the TrackStatiTunesUpdateWin.pl script which only supports iTunes on Windows to actually export the data to iTunes. A complete export will generate a TrackStat_iTunes_Complete.txt file, the continously written history file when playing and changing ratings will generate a TrackStat_iTunes_Hist.txt file.<br><br>The export module is prepared for having separate libraries in iTunes and SlimServer, for example the iTunes library can be on a Windows computer in mp3 format and the SlimServer library can be on a Linux computer with flac format. The music path and file extension parameters will in this case be used to convert the exported data so it corresponds to the paths and files used in iTunes. If you are running iTunes and SlimServer on the same computer towards the same library the music path and file extension parameters can typically be left empty.",
		'alwaysRescanTrack' => 1,
		'clearEnabled' => 0,
		'exitScanTrack' => \&exitScanTrack,
		'scanText' => 'Export',
		'properties' => [
			{
				'id' => 'itunesoutputdir',
				'name' => 'Output directory',
				'description' => 'Full path to the directory to write the export to',
				'type' => 'text',
				'validate' => \&Slim::Utils::Validate::isDir,
				'value' => defined(Slim::Utils::Prefs::get("plugin_trackstat_itunes_export_dir"))?Slim::Utils::Prefs::get("plugin_trackstat_itunes_export_dir"):Slim::Utils::Prefs::get('playlistdir')
			},
			{
				'id' => 'itunesextension',
				'name' => 'File extension in iTunes',
				'description' => 'File extension in iTunes (for example .mp3), empty means same file extension as in SlimServer',
				'type' => 'text',
				'value' => Slim::Utils::Prefs::get("plugin_trackstat_itunes_export_replace_extension")
			},
			{
				'id' => 'itunesmusicpath',
				'name' => 'Music path in iTunes',
				'description' => 'Path to main music directory in iTunes, empty means same music path as in SlimServer',
				'type' => 'text',
				'value' => Slim::Utils::Prefs::get("plugin_trackstat_itunes_export_library_music_path")
			},
			{
				'id' => 'itunesslimservermusicpath',
				'name' => 'Music path in SlimServer',
				'description' => 'Path to main music directory in SlimServer, empty means same music path as in SlimServer',
				'type' => 'text',
				'validate' => \&Plugins::TrackStat::Plugin::validateIsDirOrEmpty,
				'value' => Slim::Utils::Prefs::get("plugin_trackstat_itunes_library_music_path")
			},
			{
				'id' => 'itunesdynamicupdate',
				'name' => 'Continously write history file',
				'description' => 'Continously write a history file when ratings are changed and songs are played in SlimServer',
				'type' => 'checkbox',
				'value' => defined(Slim::Utils::Prefs::get("plugin_trackstat_itunes_enabled"))?Slim::Utils::Prefs::get("plugin_trackstat_itunes_enabled"):0
			}			
		]
	);
	if(Plugins::TrackStat::Plugin::isPluginsInstalled(undef,"MultiLibrary::Plugin")) {
		my $properties = $functions{'properties'};
		my $values = Plugins::TrackStat::Storage::getSQLPropertyValues("select id,name from multilibrary_libraries");
		my %library = (
			'id' => 'itunesexportlibraries',
			'name' => 'Libraries to limit the export to',
			'description' => 'Limit the export to songs in the selected libraries (None selected equals no limit)',
			'type' => 'multiplelist',
			'values' => $values,
			'value' => '',
		);
		push @$properties,\%library;
		my %dynamiclibrary = (
			'id' => 'itunesexportlibrariesdynamicupdate',
			'name' => 'Limit history to libraries',
			'description' => 'Limit the continously written history file to selected libraries',
			'type' => 'checkbox',
			'value' => 1
		);
		push @$properties,\%dynamiclibrary,
	}
	return \%functions;
		
}

sub exitScanTrack
{
	my $dir = Plugins::CustomScan::Plugin::getCustomScanProperty("itunesoutputdir");
	if(!defined($dir) || ! -e $dir) {
		msg("TrackStat:iTunes: Failed, an output directory must be specified\n");
		return undef;
	}
	my $filename = catfile($dir,"TrackStat_iTunes_Complete.txt");

	my $libraries = Plugins::CustomScan::Plugin::getCustomScanProperty("itunesexportlibraries");
	debugMsg("Exporting to iTunes: $filename\n");

	my $sql = undef;
	if($libraries && Plugins::TrackStat::Plugin::isPluginsInstalled(undef,"MultiLibrary::Plugin")) {
		$sql = "SELECT track_statistics.url, tracks.title, track_statistics.lastPlayed, track_statistics.playCount, track_statistics.rating, track_statistics.added FROM track_statistics,tracks,multilibrary_track where track_statistics.url=tracks.url and (track_statistics.added is not null or track_statistics.lastPlayed is not null or track_statistics.rating>0) and tracks.id=multilibrary_track.track and multilibrary_track.library in ($libraries)";
	}else {
		$sql = "SELECT track_statistics.url, tracks.title, track_statistics.lastPlayed, track_statistics.playCount, track_statistics.rating, track_statistics.added FROM track_statistics,tracks where track_statistics.url=tracks.url and (track_statistics.added is not null or track_statistics.lastPlayed is not null or track_statistics.rating>0)";
	}

	my $ds = Plugins::TrackStat::Storage::getCurrentDS();
	my $dbh = Plugins::TrackStat::Storage::getCurrentDBH();
	debugMsg("Retreiving tracks with: $sql\n");
	my $sth = $dbh->prepare( $sql );

	my $output = FileHandle->new($filename, ">") or do {
		warn "Could not open $filename for writing.";
		return undef;
	};

	my $count = 0;
	my( $url, $title, $lastPlayed, $playCount, $rating, $added );
	eval {
		$sth->execute();
		$sth->bind_columns( undef, \$url, \$title, \$lastPlayed, \$playCount, \$rating, \$added );
		my $result;
		while( $sth->fetch() ) {
			if($url) {
				if(!defined($rating) || !$rating) {
					$rating='';
				}
				if(!defined($playCount)) {
					$playCount=1;
				}
				my $path = getiTunesURL($url);
				$title = Slim::Utils::Unicode::utf8decode($title,'utf8');
				
				if($lastPlayed) {
					$count++;
					my $timestr = strftime ("%Y%m%d%H%M%S", localtime $lastPlayed);
					print $output "$title|||$path|played|$timestr|$rating|$playCount|$added\n";
				}elsif($rating && $rating>0) {
					$count++;
					print $output "$title|||$path|rated||$rating||$added\n";
				}
			}
		}
	};
	if( $@ ) {
	    warn "Database error: $DBI::errstr,$@\n";
	}
	$sth->finish();

	close $output;
	msg("TrackStat::iTunes::Export: Exporting to iTunes completed at ".(strftime ("%Y-%m-%d %H:%M:%S",localtime())).", exported $count songs\n");
	return undef;
}

sub getiTunesURL {
	my $url = shift;
	my $replaceExtension = Plugins::CustomScan::Plugin::getCustomScanProperty("itunesextension");
	my $replacePath = Plugins::CustomScan::Plugin::getCustomScanProperty("itunesmusicpath");
	my $nativeRoot = Plugins::CustomScan::Plugin::getCustomScanProperty("itunesslimservermusicpath");
	if(!defined($nativeRoot) || $nativeRoot eq '') {
		# Use iTunes import path as backup
		$nativeRoot = Slim::Utils::Prefs::get('audiodir');
	}
	$nativeRoot =~ s/\\/\//isg;
	if(defined($replacePath) && $replacePath ne '') {
		$replacePath =~ s/\\/\//isg;
	}

	my $path = Slim::Utils::Misc::pathFromFileURL($url);
	if($replaceExtension) {
		$path =~ s/\.[^.]*$/$replaceExtension/isg;
	}

	if(defined($replacePath) && $replacePath ne '') {
		$path =~ s/\\/\//isg;
		$path =~ s/$nativeRoot/$replacePath/isg;
	}

	return $path;
}	

sub exportRating {
	my $url = shift;
	my $rating = shift;
	my $track = shift;

	if(Plugins::CustomScan::Plugin::getCustomScanProperty("itunesdynamicupdate")) {
		my $itunesurl = getiTunesURL($url);
		my $dir = Plugins::CustomScan::Plugin::getCustomScanProperty("itunesoutputdir");
		if(!defined($dir) || !-e $dir) {
			msg("TrackStat::iTunes::Export: Failed to write history file, an output directory must be specified\n");
			return;
		}
		my $filename = catfile($dir,"TrackStat_iTunes_Hist.txt");
		my $output = FileHandle->new($filename, ">>") or do {
			warn "Could not open $filename for writing.";
			return;
		};
		if(!defined($track)) {
			$track = Plugins::TrackStat::Storage::objectForUrl($url);
		}
		
		if(isAllowedToExport($track)) {
			print $output "".$track->title."|||$itunesurl|rated||$rating\n";
		}
		close $output;
	}
}

sub isAllowedToExport {
	my $track = shift;

	my $include = 1;
	my $libraries = Plugins::CustomScan::Plugin::getCustomScanProperty("itunesexportlibraries");
	if(Plugins::CustomScan::Plugin::getCustomScanProperty("itunesexportlibrariesdynamicupdate") && $libraries  && Plugins::TrackStat::Plugin::isPluginsInstalled(undef,"MultiLibrary::Plugin")) {
		my $sql = "SELECT tracks.id FROM tracks,multilibrary_track where tracks.id=multilibrary_track.track and tracks.id=".$track->id." and multilibrary_track.library in ($libraries)";
		my $dbh = Plugins::TrackStat::Storage::getCurrentDBH();
		debugMsg("Executing: $sql\n");
		eval {
			my $sth = $dbh->prepare( $sql );
			$sth->execute();
			$sth->bind_columns( undef, \$include);
			if( !$sth->fetch() ) {
				debugMsg("Ignoring track, not part of selected libraries: ".$track->url."\n");
				$include = 0;
			}
			$sth->finish();
		};
		if($@) {
			warn "Database error: $DBI::errstr, $@\n";
		}
	}
	return $include;
}
sub exportStatistic {
	my $url = shift;
	my $rating = shift;
	my $playCount = shift;
	my $lastPlayed = shift;

	if(Plugins::CustomScan::Plugin::getCustomScanProperty("itunesdynamicupdate")) {
		my $itunesurl = getiTunesURL($url);
		my $dir = Plugins::CustomScan::Plugin::getCustomScanProperty("itunesoutputdir");
		if(!defined($dir) || !-e $dir) {
			msg("TrackStat::iTunes::Export: Failed to write history file, an output directory must be specified\n");
			return;
		}
		my $filename = catfile($dir,"TrackStat_iTunes_Hist.txt");
		my $output = FileHandle->new($filename, ">>") or do {
			warn "Could not open $filename for writing.";
			return;
		};
		my $ds = Plugins::TrackStat::Storage::getCurrentDS();
		my $track = Plugins::TrackStat::Storage::objectForUrl($url);
		if(!defined $rating) {
			$rating = '';
		}
		if(defined $lastPlayed && isAllowedToExport($track)) {
			my $timestr = strftime ("%Y%m%d%H%M%S", localtime $lastPlayed);
			print $output "".$track->title."|||$itunesurl|played|$timestr|$rating\n";
		}
		close $output;
	}
}
# A wrapper to allow us to uniformly turn on & off debug messages
sub debugMsg
{
	my $message = join '','TrackStat::iTunes::Export: ',@_;
	msg ($message) if (Slim::Utils::Prefs::get("plugin_trackstat_showmessages"));
}
# other people call us externally.
*escape   = \&URI::Escape::uri_escape_utf8;

# don't use the external one because it doesn't know about the difference
# between a param and not...
#*unescape = \&URI::Escape::unescape;
sub unescape {
        my $in      = shift;
        my $isParam = shift;

        $in =~ s/\+/ /g if $isParam;
        $in =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

        return $in;
}

1;

__END__
