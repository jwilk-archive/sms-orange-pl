#!/usr/bin/perl

use strict;
use warnings;

package SmsOrangePl;

use base qw(kawute);

our $VERSION = '0.8.5';

sub version($) { $SmsOrangePl::VERSION; }
sub site($) { 'sms.orange.pl'; }
sub software_name($) { 'sms.orange.pl'; }
sub config_file($) { 'sms-orange-pl.conf'; }

sub lwp_init($)
{
  my ($this) = @_;
  my $ua = kawute::lwp_init($this);
  $ua->agent('Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.8) Gecko/20071004 Iceweasel/2.0.0.8');
  push @{$ua->requests_redirectable}, 'POST';
  return $ua;
}

sub fix_number($$)
{
  my ($this, $number) = @_;
  $this->quit('No such recipient') unless $number =~ /^(?:\+48)?(\d{9})$/;
  return $1;
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
  $width <= 300 && $height <= 90 or return undef;
  my ($x, $y);
  my $state = 0;
  for ($y = $height - 1; $y >= 0; $y--)
  {
    my $sum = 0;
    for ($x = 0; $x < $width; $x++)
    {
      $sum += token_get_pixel($image, $x, $y);
    }
    last       if $state >= 9 && $sum  > 45000;
    $state = 1 if $state  < 9 && $sum  > 30000;
    $state++   if $state  > 0 && $sum <= 30000;
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
    last if $sum > 30000;
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
    last if $sum > 5000;
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
    last if $sum > 5000;
  }
  $image->Crop(x => $x);
  $image->Quantize(colorspace => 'grayscale');
  $image->Negate();
  $image->MedianFilter(1);
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

my $signature = undef;
my $cc_phone = undef;
my $cc_email = undef;

sub set_cc($$)
{
  (my $this, $_) = @_;
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
    $this->quit('Invalid cc');
  }
}

sub main($)
{
  my ($this) = @_;
  use constant
  {
    ACTION_VOID => sub { $this->action_void(); },
    ACTION_SEND => sub { $this->action_send(); },
  };
  my $action = ACTION_SEND;
  $this->get_options(
    'send|s' =>      sub { $action = ACTION_SEND; },
    'void' =>        sub { $action = ACTION_VOID; },
    'cc=s' =>        sub { shift; $this->set_cc(shift); },
    'signature=s' => \$signature,
  );
  $this->go_home();
  $this->read_config
  (
    'signature' => sub
      { $signature = shift if not defined $signature; },
    'cc' => sub 
      { set_cc($this, shift); }
  );
  $this->reject_unpersons(0) if $this->force();
  unless (defined $signature)
  {
    $this->debug_print('No signature provided: using an empty signature');
    $signature = '';
  }

  $this->debug_print("E-mail cc: $cc_email") if defined $cc_email;
  $this->debug_print("SMS cc: $cc_phone") if defined $cc_phone;
  &{$action}();
}

sub action_send($)
{
  my ($this) = @_;
  $this->pod2usage(1) if $#ARGV != 1;

  require Encode;
  require Text::Wrap;
  require File::Temp;
  my $codeset = $this->codeset();
  $this->debug_print("Codeset: $codeset");

  binmode $_, ":encoding($codeset)" foreach ((*STDIN, *STDERR, *STDOUT));
 
  my ($recipient, $body) = @ARGV;
  $recipient = Encode::decode($codeset, $recipient);
  $body = Encode::decode($codeset, $body);
  (my $number, $recipient) = $this->resolve_person($recipient);
  $this->debug_print("Recipient: $recipient");
  $body = $this->transliterate($body);
  $body = ' ' if $body eq '';
  $signature = $this->transliterate(Encode::decode($codeset, $signature));
  $this->debug_print("Message:\n" . Text::Wrap::wrap("  ", "  ", $body) . "\n\n" . Text::Wrap::wrap("  ", "  ", $signature) . "\n");
  my $body_len = length $body;
  my $signature_len = length $signature;
  my $message_len = $body_len + $signature_len;
  $this->debug_print("Message length: $body_len + $signature_len = $message_len");
  my $ua = $this->lwp_init();
  my $uri;
  my $base_uri = "http://" . $this->site() . '/';
  my $res_home = $ua->request($this->lwp_get($base_uri));
  $res_home->is_success or $this->http_error($base_uri);
  $res_home->content =~ m{src="(?:http://sms[.]orange[.]pl/)?(Default[.]aspx[?]id=[0-9A-Za-z-]+)"} or $this->api_error('s1');
  my $uri_main = "$base_uri$1";
  my $res_main = $ua->request($this->lwp_get($uri_main));
  $res_main->is_success or $this->http_error($uri_main);
  $res_main->content =~ /src="(rotate_token[.]aspx[?]token=[0-9A-Za-z-]+)"/ or $this->api_error('t0');
  my $uri_img = "$base_uri$1";
  my $res_img = $ua->simple_request($this->lwp_get($uri_img));
  $res_img->is_success or $this->http_error($uri_img);
  my ($tmp_fh, $tmp_filename) = File::Temp::tempfile(SUFFIX => '.gif', UNLINK => 1);
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
  $this->debug_print("Token: <$token>");

  require HTML::Form;
  my $form = HTML::Form->parse($res_main);
  $form->value('SENDER' => $signature);
  $form->value('RECIPIENT' => $number);
  $form->value('SHORT_MESSAGE' => $body);
  $form->value('pass' => Encode::encode('UTF-8', $token));
  $form->value('MESSAGE_PREV' => 0);
  $form->value('ILE_ZNAKOW' => 0);
  $form->value('ILE_SMSOW' => 1);
  $this->debug_print('Sending...');
  my $click_res = $ua->simple_request($form->click());
  $click_res->is_success or $this->http_error($form->action);
  $_ = $click_res->content;
  /^Pewne pola/ and $this->api_error('s2');
  if (m{<title>Wyst\xc4\x85pi\xc5\x82 b\xc5\x82\xc4\x85d})
  {
    my $info = 'Error while sending the message';
    /zosta\xc5\x82 wyczerpany/ and $info .= ': message limit exceeded';
    /b\xc5\x82\xc4\x99dne has\xc5\x82o/ and $info .= ': invalid passphrase';
    /nie ma aktywnej us\xc5\x82ugi/ and $info .= ': service disabled for the recipient';
    $this->quit($info);
  }
  m{<div id="PageTitleText">SMS wys\xc5\x82any</div>} or $this->api_error('s3');
  $this->debug_print('Looks OK');
  $this->debug_print('Providing cc...');
  $form = HTML::Form->parse($click_res);
  $form->value('ccEmailInput' => $cc_email) if defined $cc_email;
  $form->value('ccSmsInput' => $cc_phone) if defined $cc_phone;
  my $cc_res = $ua->simple_request($form->click('Zapisz'));
  $cc_res->is_success or $this->http_error($form->action);
  exit;
}

main(__PACKAGE__);

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
