use Fcntl;
use Purple;

### pidgin-pipe-status
#
# Copyright 2022 Elliot Wolk
# License: GPLv3+
#
# loosely based on https://code.google.com/archive/p/pipe-notification/
#    Copyright (C) 2008  Armin Preiml

%PLUGIN_INFO = (
  name => "pidgin-pipe-status",
  perl_api_version => 2,
  version => "0.1",
  summary => "write status + unseen conversations to files or fifo pipes",
  description => ""
    . "Write status + unseen conversations to files.\n"
    . "  Files can be plain text files,\n"
    . "    or can be initialized on the system,\n"
    . "    outside of pidgin, with mkfifo.\n"
    . "  FIFO pipes will NOT block waiting for a reader.\n"
    . "\n"
    . "status: \$HOME/.purple/plugins/pipe-status\n"
    . "unseen: \$HOME/.purple/plugins/pipe-unseen-convs\n"
    ,
  author => "elliot.wolk\@gmail.com",
  url => "http://pidgin.im",
  load => "plugin_load",
  unload => "plugin_unload",
);

my $STATE = {
  CONVERSATIONS_BY_NAME => {},
  CURRENT_STATUS_NAME   => undef,
};

my $PLUGINS_DIR = "$ENV{HOME}/.purple/plugins";

my $FILE_STATUS = "$PLUGINS_DIR/$PLUGIN_INFO{name}-pipe-status";
my $FILE_CONVS  = "$PLUGINS_DIR/$PLUGIN_INFO{name}-pipe-convs";

sub write_status_files();
sub on_account_status_changed($$$);
sub on_conversation_updated($$);
sub plugin_init();
sub plugin_load($);
sub plugin_unload($);
sub log_info($);
sub write_file($$);

sub write_status_files(){
  my %convs = %{$$STATE{CONVERSATIONS_BY_NAME}};

  my $currentStatusName = $$STATE{CURRENT_STATUS_NAME};
  $currentStatusName = "Unknown" if not defined $currentStatusName;

  my $anyUnseen = 0;
  my $unseenTitlesFmt = "";
  for my $convName(sort keys %convs){
    my $conv = $convs{$convName};
    if($$conv{unseen}){
      $anyUnseen = 1;

      my $title = $$conv{title};
      $title =~ s/[\r\n]/ /g;
      $title =~ s/^\s+//;
      $title =~ s/\s+$//;
      $unseenTitlesFmt .= "$title\n";
    }
  }

  my $statusFmt = $anyUnseen ? "NEW\n" : "$currentStatusName\n";

  write_file($FILE_STATUS, $statusFmt);
  write_file($FILE_CONVS, $unseenTitlesFmt);
}

sub on_account_status_changed($$$){
  my ($account, $oldStatus, $newStatus) = @_;

  my $newStatusName = $newStatus->get_type()->get_name();

  my $currentStatusName = $$STATE{CURRENT_STATUS_NAME};
  if($currentStatusName ne $newStatusName){
    $$STATE{CURRENT_STATUS_NAME} = $newStatusName;
    log_info("UPDATE status=$newStatusName");
    write_status_files();
  }
}

sub on_conversation_updated($$){
  my ($conv, $type) = @_;

  my $convName = $conv->get_name();
  my $convTitle = $conv->get_title();

  my $prevConvUnseen;
  if(defined $$STATE{CONVERSATIONS_BY_NAME}{$convName}){
    $prevConvUnseen = $$STATE{CONVERSATIONS_BY_NAME}{$convName}{unseen};
  }else{
    $prevConvUnseen = 0;
  }

  my $curConvUnseen;
  if($type eq Purple::Conversation::Update::Type::UNSEEN){
    #update event is unseen-status-changed
    my $unseenCountGpointer = $conv->get_data("unseen-count");
    #cannot actually extract the count, but if any pointer is returned, its > 0
    if(defined $unseenCountGpointer){
      $curConvUnseen = 1;
    }else{
      $curConvUnseen = 0;
    }
  }else{
    $curConvUnseen = $prevConvUnseen;
  }

  $$STATE{CONVERSATIONS_BY_NAME}{$convName} = {
    name   => $convName,
    title  => $convTitle,
    unseen => $curConvUnseen,
  };

  if($prevConvUnseen != $curConvUnseen){
    log_info(sprintf("UPDATE %s=%s",
      ($curConvUnseen ? "unseen" : "seen"),
      $convTitle));
    write_status_files();
  }
}

sub plugin_init(){
  return %PLUGIN_INFO;
}

sub plugin_load($){
  my ($plugin) = @_;
  log_info("loading");

  Purple::Signal::connect(
    Purple::Accounts::get_handle(),
    "account-status-changed",
    $plugin,
    \&on_account_status_changed,
  );

  Purple::Signal::connect(
    Purple::Conversations::get_handle(),
    "conversation-updated",
    $plugin,
    \&on_conversation_updated,
  );

  my $curStatus = Purple::SavedStatus::get_current();
  $$STATE{CURRENT_STATUS_NAME} = $curStatus->get_title() if defined $curStatus;
  log_info("UPDATE status=$$STATE{CURRENT_STATUS_NAME}");
  write_status_files();
}

sub plugin_unload($){
  my ($plugin) = @_;
  $$STATE{CURRENT_STATUS_NAME} = "off";
  write_status_files();
}

sub log_info($){
  my ($str) = @_;
  chomp $str;
  $str = "$str\n";
  Purple::Debug::info($PLUGIN_INFO{name}, $str);
}

sub write_file($$){
  my ($file, $contents) = @_;
  my $fh;
  if(-p $file){
    #if pipe is not being read on the other end, write without blocking
    #  messages may be missed, but pidgin will not hang
    sysopen($fh, $file, O_RDWR|O_NONBLOCK)
      or log_info("ERROR: could not write to pipe $file\n$!\n");
  }else{
    open $fh, "> $file" or log_info("ERROR: could not write $file\n$!\n");
  }
  print $fh $contents;
  close $fh;
}

