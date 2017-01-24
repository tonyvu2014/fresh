#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use File::Temp qw(tempfile);
use Text::ParseWords qw(shellwords);
use Getopt::Long qw(GetOptionsFromArray :config posix_default permute no_ignore_case pass_through);
use File::Path qw(make_path remove_tree);
use File::Glob qw(bsd_glob);
use File::Basename qw(dirname basename);
use File::Find qw(find);
use Cwd qw(getcwd chdir);
use sort 'stable';

my $FRESH_RCFILE = $ENV{FRESH_RCFILE} ||= "$ENV{HOME}/.freshrc";
my $FRESH_PATH = $ENV{FRESH_PATH} ||= "$ENV{HOME}/.fresh";
my $FRESH_LOCAL = $ENV{FRESH_LOCAL} ||= "$ENV{HOME}/.dotfiles";
my $FRESH_BIN_PATH = $ENV{FRESH_BIN_PATH} ||= "$ENV{HOME}/bin";
my $FRESH_NO_LOCAL_CHECK = $ENV{FRESH_NO_LOCAL_CHECK} ||= 1;

sub read_freshrc {
  my ($script_fh, $script_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);
  my ($output_fh, $output_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);

  print $script_fh <<'SH';
  set -e

  _FRESH_RCFILE="$1"
  _FRESH_OUTPUT="$2"

  _output() {
    local RC_LINE _ RC_FILE
    read RC_LINE _ RC_FILE <<< "$(caller 1)"
    printf "%s %s" $RC_FILE $RC_LINE >> "$_FRESH_OUTPUT"
    for arg in "$@"; do
      printf " %q" "$arg" >> "$_FRESH_OUTPUT"
    done
    echo >> "$_FRESH_OUTPUT"
  }

  _env() {
    for NAME in "$@"; do
      if declare -p "$NAME" &> /dev/null; then
        _output env "$NAME" "$(eval "echo \"\$$NAME\"")"
      fi
    done
  }

  fresh() {
    _env FRESH_NO_BIN_CONFLICT_CHECK
    _output fresh "$@"
  }

  fresh-options() {
    _output fresh-options "$@"
  }

  if [ -e "$_FRESH_RCFILE" ]; then
    source "$_FRESH_RCFILE"
  fi
SH

  close $script_fh;

  system('bash', $script_filename, $FRESH_RCFILE, $output_filename) == 0 or exit(1);

  my @entries;
  my %default_options;
  my %env;

  while (my $line = <$output_fh>) {
    my @args = shellwords($line);
    my %entry = (
      file => shift(@args),
      line => shift(@args),
    );
    my $cmd = shift(@args);

    my %options = ();
    GetOptionsFromArray(\@args, \%options, 'marker:s', 'file:s', 'bin:s', 'ref:s', 'filter:s', 'ignore-missing') or die "Parse error at $entry{file}:$entry{line}\n";

    if ($cmd eq 'fresh') {
      if (@args == 1) {
        $entry{name} = $args[0];
      } elsif (@args == 2) {
        $entry{repo} = $args[0];
        $entry{name} = $args[1];
      } else {
        entry_error(\%entry, "Unknown option: $args[2]");
      }
      $entry{options} = {%default_options, %options};
      $entry{env} = {%env};
      undef %env;
      push @entries, \%entry;
    } elsif ($cmd eq 'fresh-options') {
      die "fresh-options cannot have args" unless (@args == 0);
      %default_options = %options;
    } elsif ($cmd eq 'env') {
      die unless @args == 2;
      $env{$args[0]} = $args[1];
    } else {
      die "Unknown command: $cmd";
    }
  }
  close $output_fh;

  unlink $script_filename;
  unlink $output_filename;

  return @entries;
}

sub apply_filter {
  my ($input, $cmd) = @_;

  my ($script_fh, $script_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);
  my ($input_fh, $input_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);
  my ($output_fh, $output_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);

  print $script_fh <<'SH';
  set -euo pipefail

  _FRESH_RCFILE="$1"
  _FRESH_INPUT="$2"
  _FRESH_OUTPUT="$3"
  _FRESH_FILTER="$4"

  fresh() {
    true
  }

  fresh-options() {
    true
  }

  source "$_FRESH_RCFILE"
  cat "$_FRESH_INPUT" | eval "$_FRESH_FILTER" > "$_FRESH_OUTPUT"
SH
  close $script_fh;

  print $input_fh $input;
  close $input_fh;

  system('bash', $script_filename, $FRESH_RCFILE, $input_filename, $output_filename, $cmd) == 0 or die;

  local $/ = undef;
  my $output = <$output_fh>;
  close $output_fh;

  unlink $script_filename;
  unlink $input_filename;
  unlink $output_filename;

  return $output;
}

sub append {
  my ($filename, $data) = @_;
  make_path(dirname($filename));
  open(my $fh, '>>', $filename) or die "$!: $filename";
  print $fh $data;
  close $fh;
}

sub readfile {
  my ($filename) = @_;
  if (open(my $fh, $filename)) {
    local $/ = undef;
    my $data = <$fh>;
    close $fh;
    return $data;
  }
}

sub read_file_line {
  my ($filename, $line_no) = @_;
  if (open(my $fh, $filename)) {
    my $line;
    while (<$fh>) {
      if ($. == $line_no) {
        $line = $_;
        last;
      }
    }
    close $fh;
    return $line;
  }
}

sub read_cwd_cmd {
  my $cwd = shift;
  my @args = @_;

  $cwd =~ s/(?!^)\/+$//;
  my $old_cwd = getcwd();
  chdir($cwd) or die "$!: $cwd";

  open(my $fh, '-|', @args) or die "$!: @args";
  local $/ = undef;
  my $output = <$fh>;
  close($fh);
  $? == 0 or die "\"@args\" returned $?";

  chdir($old_cwd) or die "$!: $old_cwd";

  return $output;
}

sub format_url {
  my ($url) = @_;
  "\033[4;34m$url\033[0m"
}

sub entry_note {
  my ($entry, $msg, $desc) = @_;

  my $content = read_file_line($$entry{file}, $$entry{line});

  print STDOUT <<EOF;
\033[1;33mNote\033[0m: $msg
$$entry{file}:$$entry{line}: $content
$desc
EOF
}

sub entry_error {
  my ($entry, $msg, $options) = @_;

  my $content = read_file_line($$entry{file}, $$entry{line});
  chomp($content);

  my $file = $$entry{file};
  $file =~ s{^\Q$ENV{HOME}\E}{~};

  print STDERR <<EOF;
\033[4;31mError\033[0m: $msg
$file:$$entry{line}: $content
EOF
  if (!$$options{skip_info}) {
    print STDERR <<EOF;

You may need to run `fresh update` if you're adding a new line,
or the file you're referencing may have moved or been deleted.
EOF
  }
  if ($$entry{repo}) {
    my $url = repo_url($$entry{repo});
    my $formatted_url = format_url($url);
    print STDERR "Have a look at the repo: <$formatted_url>\n";
  }
  exit 1;
}

sub glob_filter {
  my $glob = shift;
  my @paths = @_;

  my ($script_fh, $script_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);
  my ($output_fh, $output_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);

  print $script_fh <<'SH';
  set -euo pipefail
  IFS=$'\n'

  GLOB="$1"
  OUTPUT_FILE="$2"

  while read LINE; do
    if [[ "$LINE" == $GLOB ]]; then
      if ! echo "${LINE#$GLOB}" | grep -q /; then
        echo "$LINE"
      fi
    fi
  done > "$OUTPUT_FILE"
SH

  close $script_fh;

  open(my $input_fh, '|-', 'bash', $script_filename, $glob, $output_filename) or die "$!";

  foreach my $path (@paths) {
    print $input_fh "$path\n";
  }

  close $input_fh;
  $? == 0 or die;

  my @matches;

  while (my $line = <$output_fh>) {
    chomp($line);
    if (basename($line) !~ /^\./ || basename($glob) =~ /^\./) {
      push(@matches, $line);
    }
  }

  close $output_fh;

  unlink $script_filename;
  unlink $output_filename;

  return @matches;
}

sub prefix_filter {
  my $prefix = shift;
  my @paths = @_;
  my @matches;

  foreach my $path (@paths) {
    if (substr($path, 0, length($prefix)) eq $prefix) {
      push(@matches, $path);
    }
  }

  @matches;
}

sub remove_prefix {
  my ($str, $prefix) = @_;
  if (substr($str, 0, length($prefix)) eq $prefix) {
    $str = substr($str, length($prefix));
  }
  return $str;
}

sub make_entry_link {
  my ($entry, $link_path, $link_target) = @_;
  my $existing_target = readlink($link_path);

  if (is_relative_path($link_path)) {
    if ($link_path =~ /^\.\./) {
      entry_error $entry, "Relative paths must be inside build dir.";
    }
    return
  }

  if (defined($existing_target)) {
    if ($existing_target ne $link_target) {
      if (substr($existing_target, 0, length("$FRESH_PATH/build/")) eq "$FRESH_PATH/build/" && -l $link_path) {
        unlink($link_path);
        symlink($link_target, $link_path);
      } else {
        entry_error $entry, "$link_path already exists (pointing to $existing_target)."; # TODO: this should skip info
      }
    }
  } elsif (-e $link_path) {
    entry_error $entry, "$link_path already exists.", {skip_info => 1};
  } else {
    make_path(dirname($link_path), {error => \my $err});
    if (@$err || !symlink($link_target, $link_path)) {
      entry_error $entry, "Could not create $link_path. Do you have permission?", {skip_info => 1};
    }
  }
}

sub is_relative_path {
  my ($path) = @_;
  $path !~ /^[~\/]/
}

sub repo_url {
  my ($repo) = @_;
  if ($repo =~ /:/) {
    $repo
  } else {
    "https://github.com/$repo"
  }
}

sub repo_name {
  my ($repo) = @_;

  if ($repo =~ /:/) {
    $repo =~ s/^.*@//;
    $repo =~ s/^.*:\/\///;
    $repo =~ s/:/\//;
    $repo =~ s/\.git$//;
  }

  if ($repo =~ /github.com\//) {
    $repo =~ s/^github\.com\///;
    $repo
  } else {
    my @parts = split(/\//, $repo);
    my $end = join('-', @parts[1..$#parts]);
    "$parts[0]/$end"
  }
}

sub fresh_install {
  umask 0077;
  remove_tree "$FRESH_PATH/build.new";
  make_path "$FRESH_PATH/build.new";

  append "$FRESH_PATH/build.new/shell.sh", '__FRESH_BIN_PATH__=$HOME/bin; [[ ! $PATH =~ (^|:)$__FRESH_BIN_PATH__(:|$) ]] && export PATH="$__FRESH_BIN_PATH__:$PATH"; unset __FRESH_BIN_PATH__' . "\n";
  append "$FRESH_PATH/build.new/shell.sh", "export FRESH_PATH=\"$FRESH_PATH\"\n";

  for my $entry (read_freshrc()) {
    # TODO: remove this debug
    # use Data::Dumper;
    # print Dumper(\$entry);

    my $prefix;
    if ($$entry{repo}) {
      # TODO: Not sure if we need $repo_dir as the only difference from $prefix
      # is the trailing slash. I don't want to change the specs though.
      my $repo_name = repo_name($$entry{repo});
      my $repo_dir = "$FRESH_PATH/source/$repo_name";

      if (-d "$FRESH_LOCAL/.git" && $FRESH_NO_LOCAL_CHECK) {
        my $old_cwd = getcwd();
        chdir($FRESH_LOCAL) or die "$!: $FRESH_LOCAL";
        my $upstream_branch = `git rev-parse --abbrev-ref --symbolic-full-name \@{u} 2> /dev/null`;
        chdir($old_cwd) or die "$!: $old_cwd";

        my @parts = split(/\//, $upstream_branch);
        my $upstream_remote = $parts[0];

        if (defined($upstream_remote)) {
          my $local_repo_url = read_cwd_cmd($FRESH_LOCAL, "git", "config", "--get", "remote.$upstream_remote.url");
          chomp($local_repo_url);

          my $local_repo_name = repo_name($local_repo_url);
          my $source_repo_name = repo_name($$entry{repo});

          if ($local_repo_name eq $source_repo_name) {
            entry_note $entry, "You seem to be sourcing your local files remotely.", <<EOF;
You can remove "$$entry{repo}" when sourcing from your local dotfiles repo (${FRESH_LOCAL}).
Use `fresh file` instead of `fresh $$entry{repo} file`.

To disable this warning, add `FRESH_NO_LOCAL_CHECK=true` in your freshrc file.
EOF
            $FRESH_NO_LOCAL_CHECK = 0;
          }
        }
      }

      make_path dirname($repo_dir);

      if (! -d $repo_dir) {
        system('git', 'clone', repo_url($$entry{repo}), $repo_dir) == 0 or exit(1);
      }

      $prefix = "$repo_dir/";
    } else {
      $prefix = "$FRESH_LOCAL/";
    }

    my $matched = 0;

    my @paths;

    my $is_dir_target = defined($$entry{options}{file}) && $$entry{options}{file} =~ /\/$/;
    my $is_external_target = defined($$entry{options}{file}) && $$entry{options}{file} =~ /^[\/~]/;

    my $full_entry_name = "$prefix$$entry{name}";
    my $base_entry_name = dirname($full_entry_name);

    if ($$entry{options}{ref}) {
      if ($$entry{name} =~ /\*/) {
        # TODO: Save .fresh-order to a temp file and actually use it!
        my $dir = dirname($$entry{name});
        read_cwd_cmd($prefix, 'git', 'show', "$$entry{options}{ref}:$dir/.fresh-order")
      }

      @paths = split(/\n/, read_cwd_cmd($prefix, 'git', 'ls-tree', '-r', '--name-only', $$entry{options}{ref}));
      if ($is_dir_target) {
        @paths = prefix_filter("$$entry{name}/", @paths);
      } else {
        @paths = glob_filter("$$entry{name}", @paths);
      }
    } elsif ($is_dir_target) {
      my $wanted = sub {
        push @paths, $_;
      };
      find({wanted => $wanted, no_chdir => 1}, $full_entry_name);
    } else {
      @paths = bsd_glob($full_entry_name);
    }

    if (my $fresh_order_data = readfile($base_entry_name . '/.fresh-order')) {
      my @order_lines = map { "$base_entry_name/$_" } split(/\n/, $fresh_order_data);
      my $path_index = sub {
        my ($path) = @_;
        my ($index) = grep { $order_lines[$_] eq $path } 0..$#order_lines;
        $index = 1e6 unless defined($index);
        $index;
      };
      @paths = sort {
        $path_index->($a) <=> $path_index->($b);
      } @paths;
    } else {
      @paths = sort @paths;
    }

    for my $path (@paths) {
      unless (-d $path || $path =~ /\/\.fresh-order$/) {
        my $name = remove_prefix($path, $prefix);

        my ($build_name, $link_path, $marker);

        if (defined($$entry{options}{file})) {
          $link_path = $$entry{options}{file} || '~/.' . (basename($name) =~ s/^\.//r);
          $link_path =~ s{^~/}{$ENV{HOME}/};
          $build_name = remove_prefix($link_path, $ENV{HOME}) =~ s/^\///r =~ s/^\.//r;
          if ($is_external_target) {
            $build_name = $build_name =~ s/(?<!^~)[\/ ()]+/-/gr =~ s/-$//r;
          }
          if ($is_dir_target) {
            $build_name .= remove_prefix($name, $$entry{name});
          }
        } elsif (defined($$entry{options}{bin})) {
          $link_path = $$entry{options}{bin} || '~/bin/' . basename($name);
          $link_path =~ s{^~/}{$ENV{HOME}/};
          if ($link_path !~ /^\//) {
            entry_error $entry, '--bin file paths cannot be relative.';
          }
          $build_name = 'bin/' . basename($link_path);
        } else {
          $build_name = "shell.sh";
          $marker = '#';
        }

        if (defined($$entry{options}{marker})) {
          $marker = $$entry{options}{marker} || '#';
        }

        my $data;
        if ($$entry{options}{ref}) {
          $data = read_cwd_cmd($prefix, 'git', 'show', "$$entry{options}{ref}:$path");
        } else {
          $data = readfile($path);
        }
        if (defined $data) {
          $matched = 1;

          my $build_target = "$FRESH_PATH/build.new/$build_name";
          if (!defined($$entry{env}{FRESH_NO_BIN_CONFLICT_CHECK}) || $$entry{env}{FRESH_NO_BIN_CONFLICT_CHECK} ne 'true') {
            if (defined($$entry{options}{bin}) && -e $build_target) {
              entry_note $entry, "Multiple sources concatenated into a single bin file.", <<EOF;
Typically bin files should not be concatenated together into one file.
"$build_name" may not function as expected.

To disable this warning, add `FRESH_NO_BIN_CONFLICT_CHECK=true` in your freshrc file.
EOF
            }
          }

          my $filter = $$entry{options}{filter};
          if ($filter) {
            $data = apply_filter($data, $filter);
          }

          if (defined($marker)) {
            append $build_target, "\n" if -e $build_target;
            append $build_target, "$marker fresh:";
            if ($$entry{repo}) {
              append $build_target, " $$entry{repo}";
            }
            append $build_target, " $name";
            if ($$entry{options}{ref}) {
              append $build_target, " @ $$entry{options}{ref}";
            }
            if ($filter) {
              append $build_target, " # $filter";
            }
            append $build_target, "\n\n";
          }

          append $build_target, $data;

          if (defined($$entry{options}{bin})) {
            chmod 0700, $build_target;
          }

          if (defined($link_path) && !$is_dir_target) {
            make_entry_link($entry, $link_path, "$FRESH_PATH/build/$build_name");
          }
        }
      }
    }
    unless ($matched) {
      unless ($$entry{options}{'ignore-missing'}) {
        entry_error $entry, "Could not find \"$$entry{name}\" source file.";
      }
    }

    if ($is_dir_target && $is_external_target) {
      # TODO: can this be DRYed up with `$link_path = …`, etc` above?
      # rspec spec/fresh_spec.rb -e 'local files in nested'
      my $link_path = $$entry{options}{file} =~ s{^~/}{$ENV{HOME}/}r =~ s{/$}{}r;
      my $build_name = $$entry{options}{file} =~ s/(?<!^~)[\/ ()]+/-/gr =~ s/-$//r;
      $build_name = remove_prefix($build_name =~ s{^~/}{$ENV{HOME}/}r, $ENV{HOME}) =~ s/^\///r =~ s/^\.//r;
      make_entry_link($entry, $link_path, "$FRESH_PATH/build/$build_name");
    }
  }

  system(qw(find), "$FRESH_PATH/build.new", qw(-type f -exec chmod -w {} ;)) == 0 or die $@;

  remove_tree "$FRESH_PATH/build.old";
  rename "$FRESH_PATH/build", "$FRESH_PATH/build.old";
  rename "$FRESH_PATH/build.new", "$FRESH_PATH/build";
  remove_tree "$FRESH_PATH/build.old";

  print "Your dot files are now \033[1;32mfresh\033[0m.\n"
}

if (__FILE__ eq $0) {
  fresh_install
}
