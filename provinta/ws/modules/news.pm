#!/usr/bin/perl
#
# ������ ������ ��������
#
package news;

use strict;
use _modulebase;
use Storable qw( lock_store lock_retrieve );
use Time::Local;
use UR::readConf;
use POSIX qw( strftime );
use vars qw( @ISA );
@ISA = qw( modulebase );

my $cacheFile = ".news.store";

# init() - ������������� ������.
# ���������� ���� ��� ��� ��������� ������
# ���������:
#  $mconfig - ������ �� ��� ���������� ������ (�� ws.cf)
#  $gconfig - ������ �� ��� ���������� ���������� (�� ws.cf)
# �������� �������� ���������� ���������� �� �����������!
# ���������� undef ��� �������� ������������� ��� ����� ���������
# �� ������ ��� ����������
sub init {
	my $self = shift;
	my( $mconfig, $gconfig ) = @_;

	# ������� ������� ������� �������
	$self->SUPER::init($mconfig,$gconfig);
	
	# ��� ����� ��������� ���� � �������� ��������
        $self->{'newsdir'} = $mconfig->{'newsdir'} ||
        	return "News data directory (newsdir module config key) not specified";
        $self->{'newsdir'} = $gconfig->{'basedir'} . '/' . $self->{'newsdir'}
        	unless( $self->{'newsdir'} =~ m!^/! );
        $self->{'newsdir'} =~ s!//+!/!g;

        return "News data directory '$self->{'newsdir'}' not found"
        	unless( -d $self->{'newsdir'} );
	
	return undef;
}

# run() - ������ ������
# ���������:
#  $uri  - URI �������
#  $cgi  - CGI-��������� �������
#  $page - ������ �� ��� ���������� ������������� �������� (�� �������)
#  $pconfig - ������ �� ��� ���������� ������������ ������ ��� ������ ��������
#  $pttdata - ������ �� ��� ������ ��� ������ ��������
# ����������� ������ ��������� �������� ��������� ����������� $pttdata
# ���������� undef ��� �������� ������������� ��� ����� ���������
# �� ������ ��� ����������
sub run {
	my $self = shift;
	my( $uri, $cgi, $page, $pconfig, $pttdata ) = @_;

	# ������������ ��� ���������:
	#   $self->{'newsdir'} - ������� ��������
	#   $pconfig->{'pagetype'} - 'root' ��� 'archive'
	#   $pconfig->{'newscount'} - ���������� �������� �� ��������
	#   $pcondig->{'newsmaxage'} - ����. ���� �������� � ����
	#   $cgi->val('newspage'} - ����� �������� ��������

	# �������� ������ ��������� ������, � ����� �� �������
	# � ����� �����������
	opendir( NEWSD, $self->{'newsdir'} ) ||
		return "Error reading news file list from $self->{'newsdir'}";
        my %newsfiles = map {
		$_ => join( $;, (stat("$self->{'newsdir'}/$_"))[7,9] )
        } grep { /\.cf$/ } readdir( NEWSD );
        closedir( NEWSD );

        # �������� ������������ ������ �� ��������
        my $newsdata = -r "$self->{'newsdir'}/$cacheFile" ?
        	lock_retrieve( "$self->{'newsdir'}/$cacheFile" ) : [];
        $newsdata ||= []; # ���� ������-�� �� �����������

        # ���������� �� ������ ���������� ������ �� ������� �������������
        # ���������� ������
        my $newsdata2 = [];
        foreach my $newsp (@$newsdata) {
        	next if( $newsfiles{$newsp->{'file'}} ne $newsp->{'sizetime'} );
        	push @$newsdata2, $newsp;
        	delete $newsfiles{$newsp->{'file'}};
        }
        $newsdata = $newsdata2; undef( $newsdata2 );

        # ���� � ������� %newsfiles �������� ������, ������������� �� ����
        # �������� � �������� � ������� @$newsdata, � ����� ���������������
        # @$newsdata
	if( keys( %newsfiles ) ) {
		# ��������� �����/���������� �������
                foreach my $file ( keys %newsfiles ) {
			my $nc = new readConf( "$self->{'newsdir'}/$file" );
			unless( $nc ) {
				warn "Error reading news file '$self->{'newsdir'}/$file'";
				next;
                        }
                        my $newsp = {
				'text_root' => (
					join(' ', $nc->get("news[0]:text(root)[0]:'") ) ||
					join(' ', $nc->get("news[0]:text[0]:'") ) ),
				'text_archive' => join(' ', $nc->get("news[0]:text(archive)[0]:'") ),
				'date' => $nc->get("news[0]:date"),
				'publish' => (
					$nc->numBlocks("news[0]:publish") > 0 ?
					{ ( $nc->get("news[0]:publish[0]") ) } : {}
				),
				'file' => $file,
				'sizetime' => $newsfiles{$file},
                        };
                        unless( $newsp->{'date'} =~ /^\d{4}-\d{2}-\d{2}$/ ) {
				warn "Incorecct or missing news date in news file $file";
				next;
                        }
                        my( $y, $m, $d ) = split( /-/, $newsp->{'date'} );
                        $newsp->{'utime'} = timelocal(0,0,0,$d,$m-1,$y-1900);
                        # ���� ��� ������ �������� � ����������� ����
                        $newsp->{'date'} = join('.', reverse split( /-/, $newsp->{'date'} ) );
                        $newsp->{'publish'}{'start'} ||= '0000-00-00';
                        push @$newsdata, $newsp;
                }

                # ������������� ������ @$newsdata
		@$newsdata = sort { $b->{'utime'} <=> $a->{'utime'} } @$newsdata;

                # �������� ����� ������ ����
                lock_store( $newsdata, "$self->{'newsdir'}/$cacheFile" );
	}

	# --- ������� $pttdata �� ������ $newsdata ---

	my $pttnews = {};

	my $newspage = ($cgi->val('newspage'))[0] || 1;
	my $skipnews = ($newspage-1)*$pconfig->{'newscount'};

	# ������, ��� ���� ���������� �������� (���� ��� ����)
	$pttnews->{'page_prev'} = $newspage - 1 if( $newspage > 1 );

	my $now = time();
	my $today = strftime("%Y-%m-%d",localtime($now));

	# ������� �� ���������������� ������ ��������, ��� ���� ���������
	# ������ $skipnews;
	my $count = 0;
	foreach my $newsp ( @$newsdata ) {
		# ��������, �� ��������� �� �������
		next if( $newsp->{'publish'}{'enable'} eq '0' );
		# ��������, �������� �� ������� ��� ����� ���� ��������
		next if( $newsp->{'publish'}{$pconfig->{'pagetype'}} eq '0' );
		# �������� ��������� ��������
		next if( $newsp->{'publish'}{'start'} gt $today );
		# 'stop' ��������� ������ ��� �������
		next if( $pconfig->{'pagetype'} eq 'root' &&
			$newsp->{'publish'}{'stop'} &&
			$newsp->{'publish'}{'stop'} le $today );
		# ��������, �� �������� �� (��� ������� 'stop' ������������)
		next if( ( $pconfig->{'pagetype'} ne 'root' ||
			!$newsp->{'publish'}{'stop'} ) &&
			$newsp->{'utime'}+$pconfig->{'newsmaxage'}*24*60*60 < $now );
		# ��������� ������ $skipnews ����������
                next if( $skipnews-- > 0 );
		# ��������� ��� �������
		push @{$pttnews->{'newslist'}}, {
			'date' => $newsp->{'date'},
			'text' => ( $pconfig->{'pagetype'} eq 'root' ?
				$newsp->{'text_root'} :
				( $newsp->{'text_archive'} || $newsp->{'text_root'} ) ),
		} if( $count < $pconfig->{'newscount'} );
		
		if( $count++ >= $pconfig->{'newscount'} ) {
			# ���� ������� � ��� ��������� ��������!
			$pttnews->{'page_next'} = $newspage + 1;
			last;
		}
	}


	# �������� ���������� ������
        $pttdata->{'news_module'} = $pttnews;
	
	return undef;
}

1;
