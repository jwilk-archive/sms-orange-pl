#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long qw(:config gnu_getopt no_ignore_case);
use Pod::Usage qw(pod2usage);
use File::Temp qw(tempfile);

our $VERSION = '0.3';
my $site = 'sms.orange.pl';
my $software_name = 'sms.orange.pl';
my $config_file = 'sms-orange-pl.conf';

my $debug = 0;
my $use_bell = 0;
my $person2number;
my $number2person;
my $reject_unpersons = 0;

sub quit(;$)
{
  my ($message) = @_;
  print STDERR "\a" if $use_bell;
  print STDERR "$message\n" if defined $message;
  exit 1; 
}

sub error($$)
{
  my ($message, $code) = @_;
  $message .= " ($code)" if $debug;
  quit $message; 
}

sub api_error($) { error 'API error', "code: $_[0]"; }

sub http_error($) { error 'HTTP error', $_[0]; }

sub debug($) { print STDERR "$_[0]\n" if $debug; };

sub lwp_init()
{
  require LWP::UserAgent;
  require HTTP::Cookies;
  my $ua = new LWP::UserAgent();
  $ua->timeout(30);
  $ua->agent('Mozilla/5.0');
  $ua->env_proxy();
  $ua->cookie_jar(new HTTP::Cookies(file => './cookie-jar.txt', autosave => 1, ignore_discard => 1));
  push @{$ua->requests_redirectable}, 'POST';
  return $ua;
}

sub lwp_get($)
{
  require HTTP::Request;
  return new HTTP::Request(GET => shift);
}

sub lwp_post()
{
  require HTTP::Request;
  return new HTTP::Request(POST => shift);
}

sub expand_tilde($)
{
  ($_) = @_;
  s{^~([^/]*)}{length $1 > 0 ? (getpwnam($1))[7] : ( $ENV{'HOME'} || $ENV{'LOGDIR'} )}e;
  return $_;
}

sub transliterate($)
{
  require Text::Unidecode;
  my ($text) = @_;
  Text::Unidecode::unidecode($text);
  return $text;
}

sub codeset()
{
  require I18N::Langinfo; import I18N::Langinfo qw(langinfo CODESET);
  my $codeset = langinfo(CODESET()) or die;
  return $codeset;
}

sub resolve_number($)
{
  my ($number) = @_;
  if (defined $number2person)
  {
    open N2P, '-|:encoding(utf-8)', $number2person, $number or quit q(Can't invoke resolver);
    $_ = <N2P>;
    close N2P;
    my ($person) = split /\t/ if defined $_;
    return "$person <$number>" if defined $person;
  }
  return undef if $reject_unpersons;
  return "<$number>";
}

sub resolve_person($)
{
  my ($number, $recipient);
  ($recipient) = @_;
  if ($recipient =~ /[^+\d]/ and defined $person2number)
  {
    open P2N, '-|:encoding(utf-8)', $person2number, $recipient or quit q(Can't invoke resolver);
    my @phonebook = <P2N>;
    close P2N;
    if ($#phonebook == 0)
    {
      ($_, $number) = split /\t/, $phonebook[0];
    }
    elsif ($#phonebook > 0)
    {
      print STDERR "Ambiguous recipient, please make up your mind:\n";
      print STDERR "  $_" foreach @phonebook;
      quit;
    }
    else
    {
      $number = '';
    }
  }
  else
  {
    $number = $recipient;
  }
  quit 'No such recipient' unless $number =~ /^(?:\+48)?(\d{9})$/;
  $number = $1;
  $recipient = resolve_number($number);
  quit 'No such recipient' unless defined $recipient;
  return ($number, $recipient);
}

sub get_term_size()
{
  my ($w, $h);
  eval { require Term::Size; };
  unless ($@)
  {
    if (open TTY, '<', '/dev/tty')
    {
      ($w, $h) = Term::Size::chars(*TTY{IO});
      close TTY;
    }
    ($w, $h) = Term::Size::chars(*STDOUT{IO}) unless defined $w and defined $h;
    ($w, $h) = Term::Size::chars(*STDERR{IO}) unless defined $w and defined $h;
    ($w, $h) = Term::Size::chars(*STDIN{IO})  unless defined $w and defined $h;
  }
  ($w, $h) = ($ENV{COLUMNS}, $ENV{LINES}) unless defined $w and defined $h;
  ($w, $h) = (80, 25) unless defined $w and defined $h;
  return ($w, $h);
}

sub token_get_pixel($$$)
{
  my ($image, $x, $y) = @_;
  my ($r, $g, $b, $a) = split ',', $image->Get("pixel[$x,$y]") . "\n";
  return $r + $g + $b if $r + $g <= 3 * $b;
  return 0;  
}

sub token_read_image($)
{
  my ($filename) = @_;
  eval { require Graphics::Magick; };
  return undef if $@;
  my $image = new Graphics::Magick();
  $image->Read($filename);
  my $width = $image->Get('width');
  my $height = $image->Get('height');
  $width == 268 && $height == 80 or return undef;
  my ($x, $y);
  my $state = 0;
  for ($y = $height - 1; $y >= 0; $y--)
  {
    my $sum = 0;
    for ($x = 0; $x < $width; $x++)
    {
      $sum += token_get_pixel($image, $x, $y);
    }
    $state++ if $state == 0 && $sum  > 20000;
    $state++ if $state == 1 && $sum <= 20000;
    last     if $state == 2 && $sum  > 20000;
  }
  $height = $y;
  $image->Crop(height => $height);
  $state = 0;
  for ($y = 0; $y < $height; $y++)
  {
    my $sum = 0;
    for ($x = 0; $x < $width; $x++)
    {
      $sum += token_get_pixel($image, $x, $y);
    }
    last if $sum > 20000;
  }
  $image->Crop(y => $y);
  $height -= $y;
  for ($x = $width - 1; $x >= 0; $x--)
  {
    my $sum = 0;
    for ($y = 0; $y < $height; $y++)
    {
      $sum += token_get_pixel($image, $x, $y);
    }
    last if $sum > 4000;
  }
  $width = $x;
  $image->Crop(width => $width);
  for ($x = 0; $x < $width; $x++)
  {
    my $sum = 0;
    for ($y = 0; $y < $height; $y++)
    {
      $sum += token_get_pixel($image, $x, $y);
    }
    last if $sum > 2000;
  }
  $image->Crop(x => $x);
  $image->Quantize(colorspace => 'grayscale');
  $image->Negate();
  $image->Normalize();
  my ($twidth, $theight) = get_term_size();
  $image->Resize(geometry => "${twidth}x${theight}");
  $width = $image->Get('width');
  $height = $image->Get('height');
  my @chars = (' ', ' ', ' ', ' ', ' ', '.', ':', '#');
  if ($ENV{'TERM'} eq 'linux')
  {
    $chars[5] = "\e[12;1;30m0\e[10;0m";
    $chars[6] = "\e[12;1m0\e[10;0m";
    $chars[7] = "\e[12;1m[\e[10;0m";
  }
  @_ = ();
  for ($y = 0; $y < $height; $y++)
  {
    for ($x = 0; $x < $width; $x++)
    {
      $_ = $image->Get("pixel[$x,$y]");
      s/,.*//;
      $_ >>= 5;
      push @_, $chars[$_];
    }
    push @_, "\n";
  }
  return join '', @_;
}

sub read_token()
{
  print 'Type in the token: ';
  $_ = <STDIN>;
  s/\s//g;
  return $_;
}

use constant
{
  ACTION_VOID => 0,
  ACTION_SEND => 1,
  FAKE_DOMAIN => 'anonymous.orange.pl.invalid',
};

my $action = ACTION_SEND;
my $force = 0;
my $signature = undef;
my $cc_phone = undef;
my $cc_email = undef;

sub set_cc($)
{
  ($_) = @_;
  if (/^[!-z]+@[!-z]+$/)
  {
    $cc_email = $_;
  }
  elsif (/^(?:\+?48)?(\d{9})/)
  {
    $cc_phone = $1;
  }
  else
  {
    quit 'Invalid cc'; 
  }
}

GetOptions(
  'send|s' =>         sub { $action = ACTION_SEND; },
  'void' =>           sub { $action = ACTION_VOID; },
  'cc=s' =>           sub { shift; set_cc shift; },
  'signature=s' =>    \$signature,
  'force' =>          \$force,
  'version' =>        sub { quit "$software_name, version $VERSION"; },
  'debug' =>          \$debug,
  'help|h|?' =>       sub { pod2usage(1); }
) or pod2usage(1);
my $env = $software_name;
$env =~ s/\W//g;
$env =~ y/a-z/A-Z/;
$env .= '_HOME';
my $home = exists $ENV{$env} ? $ENV{$env} : "$ENV{'HOME'}/.$software_name/";
chdir $home or quit "Can't change working directory to $home";

sub read_config(%)
{
  require Apache::ConfigFile;
  my (%conf_vars) = @_;
  my $ac = Apache::ConfigFile->read(file => $config_file, ignore_case => 1, fix_booleans => 1, raise_error => 1);
  foreach my $context (($ac, scalar $ac->cmd_context(site => $site)))
  {
    next unless $context =~ /\D/;
    foreach my $var (keys %conf_vars)
    {
      while (defined (my $val = $context->cmd_config($var)))
      {
        $conf_vars{$var}($val) if defined $val;
      }
    }
  }
}

read_config
(
  'signature' => sub
    { $signature = shift if not defined $signature; },
  'number2person' => sub 
    { $number2person = expand_tilde(shift); },
  'person2number' => sub 
    { $person2number = expand_tilde(shift); },
  'rejectunpersons' => sub 
    { $reject_unpersons = shift; },
  'debug' => sub 
    { $debug = shift; },
  'usebell' => sub
    { $use_bell = shift; },
  'cc' => \&set_cc
);

$reject_unpersons = 0 if $force;
unless (defined $signature)
{
  debug 'No signature provided: using an empty signature';
  $signature = '';
}

debug "E-mail cc: $cc_email" if defined $cc_email;
debug "SMS cc: $cc_phone" if defined $cc_phone;

if ($action == ACTION_VOID)
{
  exit;
}
else
{
  pod2usage(1) if $#ARGV != 1;

  require Encode;
  require Text::Wrap;
  my $codeset = codeset();
  debug "Codeset: $codeset";

  binmode $_, ":encoding($codeset)" foreach ((*STDIN, *STDERR, *STDOUT));
 
  my ($recipient, $body) = @ARGV;
  $recipient = Encode::decode($codeset, $recipient);
  $body = Encode::decode($codeset, $body);
  (my $number, $recipient) = resolve_person $recipient;
  debug "Recipient: $recipient";
  $body = transliterate($body);
  $body = ' ' if $body eq '';
  $signature = transliterate(Encode::decode($codeset, $signature));
  debug "Message:\n" . Text::Wrap::wrap("  ", "  ", $body) . "\n\n" . Text::Wrap::wrap("  ", "  ", $signature) . "\n";
  my $body_len = length $body;
  my $signature_len = length $signature;
  my $message_len = $body_len + $signature_len;
  debug "Message length: $body_len + $signature_len = $message_len";
  my $ua = lwp_init();
  my $uri;
  my $base_uri = "http://$site/";
  my $res_home = $ua->simple_request(lwp_get $base_uri);
  $res_home->is_success or http_error $base_uri;
  $res_home->content =~ /src="(Default[.]aspx[?]id=[0-9A-Za-z-]+)"/ or api_error 's1';
  my $uri_main = "$base_uri$1";
  my $res_main = $ua->request(lwp_get $uri_main);
  $res_main->is_success or http_error $uri;
  $res_main->content =~ /src="(rotate_token[.]aspx[?]token=[0-9A-Za-z-]+)"/;
  my $uri_img = "$base_uri$1";
  my $res_img = $ua->simple_request(lwp_get $uri_img);
  $res_img->is_success or http_error $uri_img;
  my ($tmp_fh, $tmp_filename) = tempfile(SUFFIX => '.gif', UNLINK => 1);
  print {$tmp_fh} $res_img->content;
  close $tmp_fh;
  my $token = token_read_image $tmp_filename;
  if (defined $token)
  {
    print "$token\n";
  }
  else
  {
    print "Unable to display token: '$tmp_filename'\n"
  }
  $token = read_token();
  debug "Token: <$token>";

  require HTML::Form;
  my $form = HTML::Form->parse($res_main);
  $form->value('SENDER' => $signature);
  $form->value('RECIPIENT' => $number);
  $form->value('SHORT_MESSAGE' => $body);
  $form->value('pass' => Encode::encode('UTF-8', $token));
  $form->value('MESSAGE_PREV' => 0);
  $form->value('ILE_ZNAKOW' => 0);
  $form->value('ILE_SMSOW' => 1);
  debug 'Sending...';
  my $click_res = $ua->simple_request($form->click());
  $click_res->is_success or http_error $form->action;
  $_ = $click_res->content;
  /^Pewne pola/ and api_error 's2';
  if (m{<title>Wyst\xc4\x85pi\xc5\x82 b\xc5\x82\xc4\x85d})
  {
    my $info = 'Error while sending the message';
    /zosta\xc5\x82 wyczerpany/ and $info .= ': message limit exceeded';
    /b\xc5\x82\xc4\x99dne has\xc5\x82o/ and $info .= ': invalid passphrase';
    /nie ma aktywnej us\xc5\x82ugi/ and $info .= ': service disabled for the recipient';
    quit $info;
  }
  m{<div id="PageTitleText">SMS wys\xc5\x82any</div>} or api_error 's3';
  debug 'Looks OK';
  debug 'Providing cc...';
  $form = HTML::Form->parse($click_res);
  $form->value('ccEmailInput' => $cc_email) if defined $cc_email;
  $form->value('ccSmsInput' => $cc_phone) if defined $cc_phone;
  my $cc_res = $ua->simple_request($form->click('Zapisz'));
  $cc_res->is_success or http_error $form->action;
}

__END__

=head1 NAME

sms-orange-pl -- send SMs via sms.orange.pl gateway

=head1 SYNOPSIS

=over 4

=item sms.orange.pl [-s] [--force] [--signature I<< <signature> >>] I<< <phone-number> >> I<< <text> >>

=back

=head1 ENVIRONMENT

SMSORANGEPL_HOME (default: F<$HOME/.sms-orange-pl/>)

=head1 FILES

=over 4

=item F<$ERAOMNIX_HOME/sms-orange-pl.conf>

=item F<$ERAOMNIX_HOME/cookie-jar.txt>

=back

=head1 AUTHOR

Written by Jakub Wilk E<lt>ubanus@users.sf.netE<gt>.

=head1 COPYRIGHT

You may redistribute copies of B<sms-orange-pl> under the terms of the GNU General Public License, version 2.

=cut

vim:ts=2 sw=2 et
