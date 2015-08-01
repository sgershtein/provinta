#!/usr/bin/perl

#
# TODO:
#  - ������������� ����� ��� ������ (404 � �.�.), �������� ����
#    ������ �� �������� ���� � ������ �� �����. ��� ����� ������
#    ����� ����������� ������, ����������� ��� 404-�� ������
#  - ������ ����������� ������������ warn � die, ����� ��������� ��
#    ������� �������� � ���� � ���������� �� email/sms
#  - ����������� �������.  �������������� �������� (��� Query-string)
#    ����� ������������ (����������� � ����� ����� ���������).  ���
#    ����������� ������� � ������� "������� ��������" ����� �� ��������
#    ����, �������� ������ �� ��������.
#  - ������ ����. ���������� ��������, � ����� ����. ����� ������ (�����
#    ������), ����� �������� fcgi ������������� ����������
#

use strict;
use FCGI;
use UR::CGI;
use UR::ptt3;
use UR::readConf;
use POSIX qw( isatty );

use lib qw( @INC );


# �������� ���� ������������ �����
my $wsconfigFile = '/web/convert/provinta/ws/ws.cf';

# ������� ����������� ptt-�������
ptt3::setfilter('href', \&filter_href );

# �������������� FCGI
my $fcgi = FCGI::Request() || die "Error initializing FCGI::Request: $!";

# �������� ���� ������������ � �������� � ������� ���������� ������
my( $config, $modules, $menudata, $pagedata ) = buildWSdata();

die "Not a CGI call. Config syntax is OK\n" if( isatty(0) );

# �������� ���� ��������� ��������
while( $fcgi->Accept() >= 0 ) {

	my $cgi = new CGI() || die "This must be called as a CGI script";

        my $uri = $ENV{'PATH_INFO'} || $ENV{'REDIRECT_PATH_INFO'} || '/';
        my $url = $ENV{'CHARSET_HTTP_METHOD'} . $ENV{'SERVER_NAME'} . $config->{'uriprefix'} . $uri;

        my $pttdata = {
        	'menu' => $menudata,
        	'uri' => $uri,
        	'url' => $url,
        	'uriprefix' => $config->{'uriprefix'},
                'ENV' => { %ENV },
        };

        # ���������� � ������� ������������� ��������
        generatePage( $pttdata, $cgi, $uri );

}

exit;

#####################################

#
# ��������� ���������� � ������ ��������
#
sub generatePage {
	my( $pttdata, $cgi, $uri ) = @_;

        my $page = $pagedata->{$uri};

        if( !$page ) {

        	# ����� ������ ���� �������� ����?
        	if( $pagedata->{$uri . '/'} ) {
        		$cgi->print("Status: 301 Moved permanently\n");
                	$cgi->location( filter_href($uri . '/') );
                	return;
        	}
        	
		# ������ 404
		$page = $pagedata->{':error404:'};
		$cgi->print("Status: 404 Document not found\n");
		die "Page ':error404:' not defined" unless( $page );
        }
		
        # ���� ��� ������ �������� ���������� ������� ������, ������� ��
        foreach my $module ( @{$page->{'modules'}} ) {
                eval {
                	$modules->{$module->{'name'}}{'obj'}->run(
                		$uri,
                		$cgi,
                		$page,
                		$module->{'config'},
                		$pttdata,
                	);
                };
                if( $@ ) {
                	# ������ ������ ������
			$page = $pagedata->{':error_module:'};
			$pttdata->{'module_error_text'} = $@;
			$pttdata->{'module_error_name'} = $module->{'name'};
			$cgi->print("Status: 500 Internal Server Error\n");
			die "Page ':error_module:' not defined" unless( $page );
			last;
                }
        }

	# ���������� �������������
        if( $page->{'redirect'} ) {
                # ��������
       		$cgi->print("Status: 302 Moved temporarily\n");
                $cgi->location( filter_href($page->{'redirect'}) );
                return;
        }

        $pttdata->{'page'} = $page;

        $cgi->print( ptt3::parser( {
                'path' => $config->{'pttdir'},
                'index' => ($page->{'pattern'}||$config->{'pttdefault'}||'???'),
                'global' => $pttdata,
                'filter' => 'html',
                'extrapath' => [ split( /\s+/, $config->{'pttextradirs'} ) ],
                'warn' => ( $config->{'pttnowarn'} ? 0 : 1 ),
       	}, $pttdata ) );
	
}

#
# ��������� ���������� �������� ������ �� ������ ��������� ������� �����
#
sub buildWSdata {

	my $config = {};
	my $modules = {};
	my $menudata = [];
	my $pagedata = {};

	# ���������� �������� ���� ������������
	my $wsconf = new readConf( $wsconfigFile )
		|| die "Error reading website config file $wsconfigFile";

	# �������� ������ �� ��������� �������

        my %config = $wsconf->get("config[0]");
        die "No 'config[0]' block found in configuration file $wsconfigFile"
        	unless( keys %config );
        $config = {
		( map { $_ => $config{$_} } ( grep{ !ref($config{$_}) } keys %config ) ),
        };

        # ������������� �������
        $config->{'basedir'} .= '/' unless( $config->{'basedir'} =~ m!/$! );
        foreach( qw( pttdir modulesdir ) ) {
		$config->{$_} = $config->{'basedir'}.$config->{$_}
			unless( $config->{$_} =~ m!^/! );
        }

        # ------------------------------------------------------------- #

        # �������� ������ �� ������� � ��������� ��
        unshift @INC, $config->{'modulesdir'} if( $config->{'modulesdir'} );
        my $nmodules = $wsconf->numBlocks('modules') > 0 ?
        	$wsconf->numBlocks('modules[0]:module') : 0;
        for( my $i = 0; $i < $nmodules; $i++ ) {
		my $modname = $wsconf->getBlockName("modules[0]:module[$i]") ||
                	die "Module name not defined in block 'modules[0]:module[$i]' of $wsconfigFile";
                my $modcode = $wsconf->get("modules[0]:module[$i]:code");
                my $mconfig = { $wsconf->get("modules[0]:module[$i]:config[0]") };
                die "Module '$modcode' not found" unless( -r "$config->{'modulesdir'}/$modcode" );

                # ���������� ������
                my $modobj = eval {
			die "Error compiling module '$modcode': $@ "
				unless( require "$config->{'modulesdir'}/$modcode" );

                        # �������� �������
                        my $obj = eval "new $modname();";
                        die "Error creating object '$modname': $@" if( $@ );
                        die "Could not create object '$modname'"
                        	if( ref( $obj ) ne $modname );

                        # ������������� ������
                        my $err = $obj->init( $mconfig, $config );
                        die "Error initializing module '$modname': $err" if( $err );
                        
			$obj;
                };
                die "Error loading module '$modcode': $@" if( $@ );
                $modules->{$modname} = {
                	'code' => $modcode,
			'config' => $mconfig,
			'obj' => $modobj,
                }
        }

        # ------------------------------------------------------------- #

	# �������� ������ �� ����;
	my $nchapts = $wsconf->numBlocks('menu[0]:chapter');
        for( my $i = 0; $i < $nchapts; $i++ ) {
		my %chapter = $wsconf->get("menu[0]:chapter[$i]");
		die "Menu structure error in 'menu[0]:chapter[$i]' block of $wsconfigFile"
			unless( keys( %chapter ) );
                my $nitems = $wsconf->numBlocks("menu[0]:chapter[$i]:item");
                next unless( $nitems > 0 );
		my $chapName = $wsconf->getBlockName("menu[0]:chapter[$i]");

                my $menuchapter = {
			'_id' => $chapName,
			( map { $_ => $chapter{$_} } ( grep{ !ref($chapter{$_}) } keys %chapter ) ),
                };

                for( my $j = 0 ; $j < $nitems ; $j++ ) {
			my %item = $wsconf->get("menu[0]:chapter[$i]:item[$j]");
			die "Menu structure error in 'menu[0]:chapter[$i]:item[$j]' block of $wsconfigFile"
				unless( keys( %item ) );
                        my $itemName = $wsconf->getBlockName("menu[0]:chapter[$i]:item[$j]");
                        push @{$menuchapter->{'items'}}, {
				'_id' => "$chapName:$itemName",
				( map { $_ => $item{$_} } ( grep{ !ref($item{$_}) } keys %item ) ),
                        };
                }
                $menuchapter->{'_itemcount'} = scalar( @{$menuchapter->{'items'}} );
                push @$menudata, $menuchapter;
        }

	die "Menu is not defined in website config file $wsconfigFile"
		unless( @$menudata > 0 );

        # ------------------------------------------------------------- #

	# ������ �������� ������ �� ��������� �����
	my $npages = $wsconf->numBlocks('pages[0]:uri');
        for( my $i = 0; $i < $npages; $i++ ) {
		my %uri = $wsconf->get("pages[0]:uri[$i]");
		die "Pages structure error in 'pages[0]:uri[$i]' block of $wsconfigFile"
			unless( keys( %uri ) );
		my $uri = $wsconf->getBlockName("pages[0]:uri[$i]");
		die "No uri given in block 'pages[0]:uri[$i]' of $wsconfigFile"
			unless( $uri );
                die "Uri '$uri' defined twice in $wsconfigFile"
                	if( $pagedata->{$uri} );
		$pagedata->{$uri} = {
			'_uri' => $uri,
			( map { $_ => $uri{$_} } ( grep{ !ref($uri{$_}) } keys %uri ) ),
		};
		# ���������� ���� � ��������
		if( $wsconf->numBlocks("pages[0]:uri[$i]:path") > 0 ) {
                	my $nitems = $wsconf->numBlocks("pages[0]:uri[$i]:path[0]:item");
                        my $path = [];
                	for( my $j=0; $j < $nitems; $j++ ) {
				my %item = $wsconf->get("pages[0]:uri[$i]:path[0]:item[$j]");
				die "Path structure error in 'pages[0]:uri[$i]:path[0]:item[$j]' block of $wsconfigFile"
					unless( keys( %item ) );
                        	push @$path, {
					( map { $_ => $item{$_} } ( grep{ !ref($item{$_}) } keys %item ) ),
                        	};
                	}
                	$pagedata->{$uri}{'path'} = $path;
                }
                # ���������� ������� � ������� �������
                my $mcount = $wsconf->numBlocks("pages[0]:uri[$i]:module");
                for( my $k=0; $k < $mcount; $k++ ) {
                	my $modname = $wsconf->getBlockName("pages[0]:uri[$i]:module[$k]");
                        die "Uknown module '$modname' referenced for page '$uri'"
                        	unless( $modules->{$modname} );
			my %module = $wsconf->get("pages[0]:uri[$i]:module[$k]");
			push @{$pagedata->{$uri}{'modules'}}, {
				'name' => $modname,
				'config' => {
					( map { $_ => $module{$_} } ( grep{ !ref($module{$_}) } keys %module ) ),
				},
			};
                }
	}
	       	
	return( $config, $modules, $menudata, $pagedata );
}


# ----------------
# ������� ��� ptt
# ----------------

# ����������� ������.
#  - �� ��������� ��������� �������
#  - ���� ���������� �� //, �� ������� �� ���������, ��������� /
#  - ���� ���������� �� (https?|ftp|news);// - ������� �� ���������
sub filter_href {
	my $href = shift;
	if( $href =~ m#^/# && !($href =~ s#^//#/#) ) {
		$href = $config->{'uriprefix'} . $href;
        }
       	return $href
}
