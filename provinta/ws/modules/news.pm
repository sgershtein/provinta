#!/usr/bin/perl
#
# Модуль вывода новостей
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

# init() - инициализация модуля.
# вызывается один раз при подгрузке модуля
# параметры:
#  $mconfig - ссылка на хеш параметров модуля (из ws.cf)
#  $gconfig - ссылка на хеш глобальных параметров (из ws.cf)
# Изменять значения глобальных параметров не допускается!
# возвращает undef при успешной инициализации или текст сообщения
# об ошибке при неуспешной
sub init {
	my $self = shift;
	my( $mconfig, $gconfig ) = @_;

	# сначала вызовем базовый вариант
	$self->SUPER::init($mconfig,$gconfig);
	
	# нам нужно сохранить путь к каталогу новостей
        $self->{'newsdir'} = $mconfig->{'newsdir'} ||
        	return "News data directory (newsdir module config key) not specified";
        $self->{'newsdir'} = $gconfig->{'basedir'} . '/' . $self->{'newsdir'}
        	unless( $self->{'newsdir'} =~ m!^/! );
        $self->{'newsdir'} =~ s!//+!/!g;

        return "News data directory '$self->{'newsdir'}' not found"
        	unless( -d $self->{'newsdir'} );
	
	return undef;
}

# run() - работа модуля
# параметры:
#  $uri  - URI запроса
#  $cgi  - CGI-параметры запроса
#  $page - ссылка на хеш параметров запрашиваемой страницы (из конфига)
#  $pconfig - ссылка на хеш параметров конфигурации модуля для данной страницы
#  $pttdata - ссылка на хеш данных для вывода страницы
# результатом работы процедуры является изменение содержимого $pttdata
# возвращает undef при успешной инициализации или текст сообщения
# об ошибке при неуспешной
sub run {
	my $self = shift;
	my( $uri, $cgi, $page, $pconfig, $pttdata ) = @_;

	# интересующие нас параметры:
	#   $self->{'newsdir'} - каталог новостей
	#   $pconfig->{'pagetype'} - 'root' или 'archive'
	#   $pconfig->{'newscount'} - количество новостей на страницу
	#   $pcondig->{'newsmaxage'} - макс. срок давности в днях
	#   $cgi->val('newspage'} - номер страницы новостей

	# построим список новостных файлов, а также их размеры
	# и время модификации
	opendir( NEWSD, $self->{'newsdir'} ) ||
		return "Error reading news file list from $self->{'newsdir'}";
        my %newsfiles = map {
		$_ => join( $;, (stat("$self->{'newsdir'}/$_"))[7,9] )
        } grep { /\.cf$/ } readdir( NEWSD );
        closedir( NEWSD );

        # зачитаем кешированные данные по новостям
        my $newsdata = -r "$self->{'newsdir'}/$cacheFile" ?
        	lock_retrieve( "$self->{'newsdir'}/$cacheFile" ) : [];
        $newsdata ||= []; # если почему-то не прочиталось

        # пробежимся по списку новостевых файлов на предмет необходимости
        # обновления данных
        my $newsdata2 = [];
        foreach my $newsp (@$newsdata) {
        	next if( $newsfiles{$newsp->{'file'}} ne $newsp->{'sizetime'} );
        	push @$newsdata2, $newsp;
        	delete $newsfiles{$newsp->{'file'}};
        }
        $newsdata = $newsdata2; undef( $newsdata2 );

        # если в массиве %newsfiles остались записи, следовательно их надо
        # зачитать и добавить к массиву @$newsdata, а потом пересортировать
        # @$newsdata
	if( keys( %newsfiles ) ) {
		# появились новые/измененные новости
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
                        # дату для вывода приведем к нормальному виду
                        $newsp->{'date'} = join('.', reverse split( /-/, $newsp->{'date'} ) );
                        $newsp->{'publish'}{'start'} ||= '0000-00-00';
                        push @$newsdata, $newsp;
                }

                # пересортируем массив @$newsdata
		@$newsdata = sort { $b->{'utime'} <=> $a->{'utime'} } @$newsdata;

                # сохраним новую версию кеша
                lock_store( $newsdata, "$self->{'newsdir'}/$cacheFile" );
	}

	# --- посроим $pttdata на основе $newsdata ---

	my $pttnews = {};

	my $newspage = ($cgi->val('newspage'))[0] || 1;
	my $skipnews = ($newspage-1)*$pconfig->{'newscount'};

	# укажем, что есть предыдущая страница (если она есть)
	$pttnews->{'page_prev'} = $newspage - 1 if( $newspage > 1 );

	my $now = time();
	my $today = strftime("%Y-%m-%d",localtime($now));

	# побежим по отсортированному списку новостей, при этом пропустим
	# первые $skipnews;
	my $count = 0;
	foreach my $newsp ( @$newsdata ) {
		# проверим, не отключена ли новость
		next if( $newsp->{'publish'}{'enable'} eq '0' );
		# проверим, подходит ли новость для этого типа страницы
		next if( $newsp->{'publish'}{$pconfig->{'pagetype'}} eq '0' );
		# проверим временной диапазон
		next if( $newsp->{'publish'}{'start'} gt $today );
		# 'stop' действует только для обложки
		next if( $pconfig->{'pagetype'} eq 'root' &&
			$newsp->{'publish'}{'stop'} &&
			$newsp->{'publish'}{'stop'} le $today );
		# проверим, не устарела ли (для обложки 'stop' приоритетней)
		next if( ( $pconfig->{'pagetype'} ne 'root' ||
			!$newsp->{'publish'}{'stop'} ) &&
			$newsp->{'utime'}+$pconfig->{'newsmaxage'}*24*60*60 < $now );
		# пропустим первые $skipnews подходящих
                next if( $skipnews-- > 0 );
		# публикуем эту новость
		push @{$pttnews->{'newslist'}}, {
			'date' => $newsp->{'date'},
			'text' => ( $pconfig->{'pagetype'} eq 'root' ?
				$newsp->{'text_root'} :
				( $newsp->{'text_archive'} || $newsp->{'text_root'} ) ),
		} if( $count < $pconfig->{'newscount'} );
		
		if( $count++ >= $pconfig->{'newscount'} ) {
			# есть новости и для следующей страницы!
			$pttnews->{'page_next'} = $newspage + 1;
			last;
		}
	}


	# сохраним результаты работы
        $pttdata->{'news_module'} = $pttnews;
	
	return undef;
}

1;
