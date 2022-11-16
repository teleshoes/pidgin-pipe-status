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
  CONFIG => {
    mtime => undef,
    ignored_regex => undef,
    conv_groups => {},
  },
};

my $PLUGINS_DIR = "$ENV{HOME}/.purple/plugins";

my $FILE_CONFIG = "$PLUGINS_DIR/$PLUGIN_INFO{name}-config.properties";
my $FILE_STATUS = "$PLUGINS_DIR/$PLUGIN_INFO{name}-pipe-status";
my $FILE_CONVS  = "$PLUGINS_DIR/$PLUGIN_INFO{name}-pipe-convs";

sub write_status_files();
sub on_account_status_changed($$$);
sub on_conversation_updated($$);
sub plugin_init();
sub plugin_load($);
sub plugin_unload($);
sub log_info($);
sub maybe_load_config();
sub load_config();
sub write_file($$);
sub mtime($);

sub write_status_files(){
  maybe_load_config();

  my %convs = %{$$STATE{CONVERSATIONS_BY_NAME}};

  my $currentStatusName = $$STATE{CURRENT_STATUS_NAME};
  $currentStatusName = "Unknown" if not defined $currentStatusName;

  my $ignoredTitleRegex = $$STATE{CONFIG}{ignored_regex};

  my @convGroups = values %{$$STATE{CONFIG}{conv_groups}};
  @convGroups = sort {
    0
    || $$b{priority} <=> $$a{priority}
    || $$a{groupName} cmp $$b{groupName}
  } @convGroups;

  log_info(join " ", map {$$_{display}} @convGroups);

  my $groupOther = {
    groupName => 'other',
    regex     => undef,
    display   => "NEW",
    priority  => 0,
  };

  my $unseenTitlesFmt = "";
  my $selectedUnseenGroup;
  for my $convName(sort keys %convs){
    my $conv = $convs{$convName};
    if($$conv{unseen}){
      my $title = $$conv{title};
      $title =~ s/[\r\n]/ /g;
      $title =~ s/^\s+//;
      $title =~ s/\s+$//;

      my $group;
      for my $convGroup(@convGroups){
        if($title =~ $$convGroup{regex}){
          $group = $convGroup;
          last;
        }
      }
      if(not defined $group){
        $group = $groupOther;
      }

      if(defined $ignoredTitleRegex and $title =~ $ignoredTitleRegex){
        log_info("ignored: $title");
      }else{
        $unseenTitlesFmt .= "$title\n";
        $selectedUnseenGroup = $group if not defined $selectedUnseenGroup;
        $selectedUnseenGroup = $group if $$group{priority} > $$selectedUnseenGroup{priority};
      }
    }
  }

  my $statusFmt = "$currentStatusName\n";
  if(defined $selectedUnseenGroup){
    $statusFmt = "$$selectedUnseenGroup{display}\n";
  }

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

sub maybe_load_config(){
  my $mtime = mtime $FILE_CONFIG;
  my $prevMtime = $$STATE{CONFIG}{mtime};
  if(not defined $mtime or not defined $prevMtime or $mtime != $prevMtime){
    log_info("loading config");
    load_config();
  }
}

sub load_config(){
  $$STATE{CONFIG}{mtime} = undef;
  $$STATE{CONFIG}{ignored_regex} = undef;
  $$STATE{CONFIG}{conv_groups} = {};

  if(-e $FILE_CONFIG){
    open my $fh, "< $FILE_CONFIG"
      or log_info("ERROR: could not read $FILE_CONFIG\n$!\n");
    my @lines = <$fh>;
    close $fh;
    $$STATE{CONFIG}{mtime} = mtime $FILE_CONFIG;

    for my $line(@lines){
      chomp $line;
      $line =~ s/#.*//;
      $line =~ s/^\s*//;
      $line =~ s/\s*$//;

      if($line eq ""){
        next;
      }elsif($line =~ /^\s*ignored\.regex\s*=\s*(.*)$/){
        my $regex = $1;
        $regex =~ s/^\s+$//;
        $regex =~ s/\s+$//;
        if($regex eq ""){
          $$STATE{CONFIG}{ignored_regex} = undef;
        }else{
          $$STATE{CONFIG}{ignored_regex} = eval { qr/$regex/ };
        }
      }elsif($line =~ /^\s*conv\.(\w+)\.(regex|display|priority)\s*=\s*(.*)$/){
        my ($groupName, $field, $value) = ($1, $2, $3);
        $value =~ s/^\s*//;
        $value =~ s/\s*$//;

        if(not defined $$STATE{CONFIG}{conv_groups}{$groupName}){
          $$STATE{CONFIG}{conv_groups}{$groupName} = {
            groupName => $groupName,
          };
        }

        if($field eq "regex"){
          $value = eval{ qr/$value/ };
        }elsif($field eq "priority"){
          if($value !~ /^-?\d+$/){
            $value = undef;
          }
        }

        if(not defined $value){
          log_info("ERROR: malformed conversation group config value: $line");
        }else{
          $$STATE{CONFIG}{conv_groups}{$groupName}{$field} = $value;
        }
      }else{
        log_info("ERROR: invalid config line: $line");
      }
    }

    for my $groupName(sort keys %{$$STATE{CONFIG}{conv_groups}}){
      my $invalid = 0;
      $invalid = 1 if not defined $$STATE{CONFIG}{conv_groups}{$groupName}{regex};
      $invalid = 1 if not defined $$STATE{CONFIG}{conv_groups}{$groupName}{display};
      $invalid = 1 if not defined $$STATE{CONFIG}{conv_groups}{$groupName}{priority};
      delete $$STATE{CONFIG}{conv_groups}{$groupName} if $invalid;
    }
  }
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

sub mtime($){
  my ($file) = @_;
  if(-e $file){
    my @stat = stat $file;
    return $stat[9];
  }else{
    return undef;
  }
}
