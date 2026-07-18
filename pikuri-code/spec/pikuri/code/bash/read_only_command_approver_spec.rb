# frozen_string_literal: true

RSpec.describe Pikuri::Code::Bash::ReadOnlyCommandApprover do
  describe 'approves provably read-only commands' do
    %w[
      ls
      ls\ -la\ /etc
      cat\ /etc/hostname
      grep\ -i\ error\ /var/log/syslog
      rg\ --hidden\ pattern\ /home/u/notes
      rg\ -z\ pattern\ /var/log
      rg\ --search-zip\ pattern\ /var/log
      df\ -h
      du\ -sh\ /home/u/Music
      ps\ aux
      free\ -m
      uname\ -a
      stat\ /etc/fstab
      head\ -n20\ /var/log/dmesg
      printenv\ HOME
      grep\ --color=never\ foo\ /tmp/x
      dpkg\ -l
      dpkg\ -l\ ruby
      dpkg\ --list
      dpkg\ -S\ /bin/ls
      dpkg\ --search\ /usr/bin/git
      dpkg\ -L\ coreutils
      dpkg\ -s\ bash
      dpkg\ --get-selections
      dpkg-query\ -W\ -f\ ruby
      apt\ search\ ruby
      apt\ show\ ruby
      apt\ list\ --installed
      apt\ policy\ nginx
      apt-cache\ search\ ruby
      systemctl\ list-units
      systemctl\ list-unit-files
      systemctl\ status\ sshd
      systemctl\ show\ nginx
      systemctl\ cat\ ssh
      systemctl\ is-active\ cron
      systemctl\ is-enabled\ cron
      dmesg
      dmesg\ -T
      dmesg\ -xT
      dmesg\ --level=err,warn,crit
      dmesg\ -l\ err
      dmesg\ -k\ --human
      dmesg\ --since\ -1\ --until\ now
      journalctl
      journalctl\ -k
      journalctl\ -u\ sshd
      journalctl\ -b\ -p\ err
      journalctl\ -r\ -n\ 100
      journalctl\ --no-pager
      journalctl\ --since\ -1h\ --until\ now
      journalctl\ -k\ --level=err,warn
      man\ smartctl
      man\ 5\ crontab
      man\ -a\ ls
      man\ -k\ disk
      man\ -w\ ls
      apropos\ disk
      whatis\ ls
    ].each do |cmd|
      it "approves: #{cmd.inspect}" do
        assert described_class.new.approves?(cmd), "expected approval for #{cmd.inspect}"
      end
    end
  end

  describe 'approves sequencer-joined chains of read-only commands' do
    # Every segment is independently a provably read-only invocation, so
    # the composition (&&, ||, ;, |) is read-only too.
    [
      'ls && pwd',
      'df -h && free -m',
      'cat a && cat b',
      'cd /home/u/notes && ls -la',
      'cd /etc && cat hostname && wc -l fstab',
      'ls&&pwd',                   # no spaces around the operator
      'ps aux | grep ssh',         # pipe
      'ls | wc -l',
      'cat a | grep b | head',     # multi-stage pipe
      'ls; pwd',                   # semicolon
      'df -h ; free -m',
      'ls || pwd',                 # logical-or
      'cd /etc && cat hostname | wc -l' # mixed operators
    ].each do |cmd|
      it "approves: #{cmd.inspect}" do
        assert described_class.new.approves?(cmd), "expected approval for #{cmd.inspect}"
      end
    end
  end

  describe 'approves write-nothing redirects, comments, and newline batches' do
    [
      'dpkg -S /bin/ls 2>&1',                 # stderr merged to stdout
      'dpkg -S /bin/ls 2>/dev/null',          # stderr discarded
      'dpkg -S /bin/ls 2>&1 || true',         # the || true error-swallow idiom
      'cat /etc/hostname >/dev/null',         # stdout discarded
      'ls>/dev/null',                         # discard glued to the command name
      'cat /etc/hostname > /dev/null 2>&1',   # both discarded, two tokens
      'ls 2>&1 | grep foo',                   # redirect composes with a pipe
      "# explain\nls",                        # leading full-line comment
      "ls\npwd\ndf -h",                       # newline-separated batch
      "dpkg -S /a 2>&1 || true\ndpkg -S /b 2>&1 || true", # the reported shape
      'systemctl list-units 2>/dev/null',     # systemctl query + safe redirect
      'dmesg --level=err,warn,crit 2>/dev/null | tail -80', # reported dmesg shape
      'dmesg -T | grep -i error',             # dmesg piped into a read-only filter
      'journalctl -k --level=err,warn 2>&1 | head -100', # the reported journalctl shape
      'journalctl -u sshd --since -1h 2>/dev/null', # journalctl query + safe redirect
      "man smartctl 2>&1 | grep -A 20 'self-test\\|--test'", # the reported man shape
      'dpkg --get-selections | grep -w install | wc -l', # the reported shape, unquoted
      # The reported batch verbatim: a comment line then many
      # `dpkg -S <unit> 2>&1 || true` probes, newline-separated.
      (['# Check which packages provided these unit files'] +
       %w[auto-cpufreq connman fcoe grub-common kbd lxc networking
          nslcd ntp ntpsec oem-config].map do |u|
         "dpkg -S /usr/lib/systemd/system/#{u}.service 2>&1 || true"
       end).join("\n")
    ].each do |cmd|
      it "approves: #{cmd.inspect}" do
        assert described_class.new.approves?(cmd), "expected approval for #{cmd.inspect}"
      end
    end
  end

  describe 'does not approve anything not provably read-only' do
    {
      'pipe'                 => 'ls | rm -rf /',
      'semicolon chain'      => 'ls; rm -rf ~',
      'and chain'            => 'cat x && rm y',
      'command substitution' => 'echo $(rm -rf ~)',
      'backtick'             => 'echo `rm -rf ~`',
      'output redirect'      => 'echo pwned > /etc/passwd',
      'append redirect'      => 'echo x >> ~/.bashrc',
      'glob'                 => 'ls *.txt',
      'tilde expansion'      => 'ls ~/secret',
      'brace expansion'      => 'rm -rf {a,b}',
      'leading env assign'   => 'FOO=bar ls',
      'relative path binary' => './ls',
      'absolute path binary' => '/bin/ls -la',
      'rm'                   => 'rm -rf /',
      'find -delete'         => 'find . -name x -delete',
      'sort -o (writes)'     => 'sort -o out.txt in.txt',
      'systemctl stop'       => 'systemctl stop sshd',
      'journalctl --vacuum'  => 'journalctl --vacuum-time=1s', # trims stored logs (=value)
      'journalctl vacuum-sz' => 'journalctl --vacuum-size=100M', # space trimmer
      'journalctl --rotate'  => 'journalctl --rotate',         # rotates journal files
      'journalctl --flush'   => 'journalctl --flush',          # moves /run journal to /var
      'journalctl relinquish'=> 'journalctl --smart-relinquish-space',
      'journalctl setup-keys'=> 'journalctl --setup-keys',     # generates FSS key pair
      'journalctl upd-catalog'=> 'journalctl --update-catalog', # rebuilds catalog index
      'journalctl vacuum mid'=> 'journalctl -u sshd --vacuum-time=1s', # mutator not first arg
      'dmesg --clear'        => 'dmesg --clear',          # wipes the ring buffer
      'dmesg -C'             => 'dmesg -C',               # short clear
      'dmesg -c'             => 'dmesg -c',               # read-clear
      'dmesg bundled clear'  => 'dmesg -xC',              # clear hidden in a short cluster
      'dmesg --console-off'  => 'dmesg --console-off',    # toggles console printing
      'dmesg --console-level'=> 'dmesg --console-level=1',# sets console level (=value)
      'dmesg -n spaced'      => 'dmesg -n 1',             # set-level, spaced argument
      'man --html (browser)' => 'man --html ls',       # renders HTML, launches $BROWSER
      'man -H (browser)'     => 'man -H ls',           # short spelling
      'man -H attached arg'  => 'man -Hfirefox ls',    # -H with attached browser
      'man bundled -H'       => 'man -aH ls',          # exec flag hidden in a short cluster
      'man --pager (exec)'   => 'man --pager=less ls', # arbitrary pager (=value)
      'man -P (exec)'        => 'man -P less ls',       # arbitrary pager, spaced arg
      'rg --pre (exec)'      => 'rg --pre=/bin/sh pat .',    # arbitrary preprocessor (=value)
      'rg --pre spaced'      => 'rg --pre /bin/sh pat .',    # preprocessor, spaced arg
      'rg --hostname-bin'    => 'rg --hostname-bin=/bin/sh pat .', # arbitrary hostname cmd
      'rg --pre mid-args'    => 'rg pat . --pre=/bin/sh',    # exec flag not first arg
      'rg --pre quote-smuggle' => "rg --''pre=/bin/sh pat .", # → --pre after quote-removal
      'dpkg install'         => 'dpkg -i pkg.deb',
      'dpkg remove'          => 'dpkg -r ruby',
      'dpkg purge'           => 'dpkg --purge ruby',
      'dpkg set-selections'  => 'dpkg --set-selections',
      'dpkg admindir before' => 'dpkg --admindir=/x -i pkg.deb', # redirect before action
      'apt install'          => 'apt install ruby -y',
      'apt remove'           => 'apt remove ruby',
      'apt update'           => 'apt update',
      'apt upgrade'          => 'apt upgrade',
      'apt -o before verb'   => 'apt -o APT::Foo=bar install ruby', # config injection before verb
      'apt-get install'      => 'apt-get install ruby', # apt-get not allowlisted at all
      'systemctl enable'     => 'systemctl enable nginx',
      'systemctl daemon-rel' => 'systemctl daemon-reload',
      'systemctl --root glob'=> 'systemctl --root=/x list-units', # leading global → not approved
      # Redirects that actually write: only fd-dup / /dev/null are safe.
      'redirect to file'     => 'cat x 2>/tmp/err',     # arbitrary stderr target
      'stdout to file'       => 'ls > out.txt',         # arbitrary stdout target
      'attached file redir'  => 'ls>out.txt',           # arbitrary target, glued → trips gate
      'devnull-lookalike'    => 'ls 2>/dev/nullx',      # not exactly /dev/null
      'devnull-suffix'       => 'ls 2>/dev/null.bak',   # /dev/null.bak is a real file
      # Comments only no-op when they START a segment.
      'mid-segment hash'     => 'ls # then rm',         # # not at segment start → trips gate
      'newline hides rm'     => "ls\nrm -rf /",         # second line is a real mutation
      'over MAX_CHAIN lines' => (['ls'] * 65).join("\n"), # too many newline segments
      'git mutation'         => 'git reset --hard',
      'dd'                   => 'dd if=/dev/zero of=/dev/sda',
      'tee (writes)'         => 'tee /etc/hosts',
      'env (runs program)'   => 'env FOO=bar ls',
      # Sequencer segments that are not all provably read-only.
      'chain with mutation'  => 'ls && rm -rf ~',
      'chain hides git'      => 'cd notes && git diff', # git stays not-approved without allow_git
      'chain hides write'    => 'cd x && tee out',
      'triple-amp'           => 'ls &&& pwd',          # segment "& pwd" has a stray &
      'trailing &&'          => 'ls && ',              # empty trailing segment
      'leading &&'           => '&& ls',               # empty leading segment
      'over MAX_CHAIN'       => (['ls'] * 65).join(' && '),
      # A pipe grants no write/exec: the escalators aren't allowlisted.
      'pipe into xargs'      => 'ls | xargs rm',       # xargs not allowlisted
      'pipe into sh'         => 'ls | sh',             # sh not allowlisted
      'pipe into tee'        => 'cat x | tee y',       # tee writes
      'pipe then redirect'   => 'ps | grep x > out',   # redirect in last segment
      'pipe into dd'         => 'cat /dev/zero | dd of=x',
      'double-semicolon'     => 'ls ;; pwd',           # empty middle segment
      'background not seq'    => 'ls & pwd',            # single & not a sequencer; trips metachar
      'pipe-amp (stderr)'    => 'ls |& grep x'         # |& leaves a stray & → metachar
    }.each do |label, cmd|
      it "does not approve: #{label} (#{cmd.inspect})" do
        refute described_class.new.approves?(cmd), "expected no approval for #{cmd.inspect}"
      end
    end
  end

  describe 'with allow_git: true (trusted-repo read-only git)' do
    # Approved only because the caller asserted repo-config trust.
    [
      'git diff',
      'git diff --cached',
      'git diff --staged',
      'git diff --stat',
      'git status',
      'git log -p',
      'git show HEAD',
      'git blame lib/foo.rb',
      'cd repo && git diff --cached', # composes with the sequencer split
      'git status | wc -l'            # composes with a read-only pipe
    ].each do |cmd|
      it "approves: #{cmd.inspect}" do
        assert described_class.new(allow_git: true).approves?(cmd), "expected approval for #{cmd.inspect}"
      end
    end

    # Trust neutralizes config-execution; it does NOT license destructive
    # git or config/repo-redirection/--output escapes — these are not approved.
    {
      'reset (destructive)'   => 'git reset --hard',
      'checkout (mutates)'    => 'git checkout .',
      'clean (deletes)'       => 'git clean -fd',
      'stash (mutates)'       => 'git stash',
      'commit (mutates)'      => 'git commit -m wip',
      'push (network/write)'  => 'git push',
      'config (writes)'       => 'git config user.email x',
      'tag (creates)'         => 'git tag v1',
      'branch -d (deletes)'   => 'git branch -d topic',
      'inline -c config'      => 'git -c core.pager=evil diff',  # global opt before verb
      'repo redirection -C'   => 'git -C /other diff',           # global opt before verb
      'diff --output= writes' => 'git diff --output=f',
      'diff --output writes'  => 'git diff --output f',
      'diff redirect'         => 'git diff > out',               # metachar, refused first
      'bare git'              => 'git'
    }.each do |label, cmd|
      it "does not approve even with allow_git: #{label} (#{cmd.inspect})" do
        refute described_class.new(allow_git: true).approves?(cmd), "expected no approval for #{cmd.inspect}"
      end
    end

    it 'still approves the plain read-only binaries (git is additive)' do
      assert described_class.new(allow_git: true).approves?('ls -la && cat foo')
    end
  end

  describe 'with allow_git default (false) — git stays not approved' do
    %w[git\ diff git\ status git\ log].each do |cmd|
      it "does not approve: #{cmd.inspect}" do
        refute described_class.new.approves?(cmd) # allow_git omitted
      end
    end
  end

  describe 'single-quoted arguments' do
    # A single-quoted span is decoded by real shell quote-removal: the
    # marks drop and the interior is kept verbatim as one literal word,
    # so a read-only command with a quoted argument approves.
    [
      "grep -w 'install'",
      "grep 'foo bar' /etc/hosts",             # quoted whitespace = one word
      "echo 'a | b'",                          # quoted sequencer is literal
      "echo 'a && b'",                         # quoted && does not split
      "grep 'a|b' /tmp/x",                     # quoted metachar is literal
      "grep 'a\"b' /tmp/x",                    # quoted double-quote is literal
      "grep ''",                               # empty quoted arg
      "dpkg --get-selections | grep -w 'install' | wc -l" # the reported shape
    ].each do |cmd|
      it "approves: #{cmd.inspect}" do
        assert described_class.new.approves?(cmd), "expected approval for #{cmd.inspect}"
      end
    end

    # Bypass guards: a quote must never let a mutating flag through. Real
    # quote-removal hands the classifiers the TRUE flag (+--clear+, not
    # +--_clear+), so an empty/mid-token quote pair collapses into the
    # flag it was hiding and is caught. Backslashes stay forbidden.
    # (See the adversarial review in the class header.)
    {
      "dmesg empty-pair clear"  => "dmesg --''clear",      # → dmesg --clear (wipes buffer)
      "dmesg mid-token clear"   => "dmesg --cl'e'ar",      # → dmesg --clear
      "dmesg empty-pair -C"     => "dmesg ''-C",           # → dmesg -C (short clear)
      "git empty-pair --output" => "git diff --''output=/tmp/x", # → --output (writes a file)
      "quoted command name"     => "'rm' -rf ~",           # → rm, not allowlisted
      "unbalanced single quote" => "grep 'foo",            # never closes → not approved
      "ansi-c quote keeps $"    => "echo $'\\n'",          # the $ trips the gate
      "quoted sequencer word"   => "ls' ; 'rm",            # one literal word "ls ; rm"
      "backslash forbidden"     => 'echo a\\;b'            # \\ stays forbidden
    }.each do |label, cmd|
      it "does not approve: #{label} (#{cmd.inspect})" do
        # allow_git so the git guard is actually exercised, not gated off.
        refute described_class.new(allow_git: true).approves?(cmd), "expected no approval for #{cmd.inspect}"
      end
    end
  end

  describe 'double-quoted arguments (inert interior only)' do
    # A double-quoted span with none of the POSIX-live bytes ($, backtick,
    # backslash) is literal exactly like a single-quoted one, so the same
    # real quote-removal applies and the command approves.
    [
      'cat /etc/hostname && echo " bytes"',    # the motivating LLM shape
      'grep "foo bar" /etc/hosts',             # quoted whitespace = one word
      'echo "a | b"',                          # quoted sequencer is literal
      'echo "done!"',                          # ! is inert under bash -c
      'grep ""',                               # empty quoted arg
      %q(grep "it's" /tmp/x),                  # single quote literal inside "..."
      'dpkg --get-selections | grep -w "install" | wc -l'
    ].each do |cmd|
      it "approves: #{cmd.inspect}" do
        assert described_class.new.approves?(cmd), "expected approval for #{cmd.inspect}"
      end
    end

    # Any POSIX-live byte inside the span → not approved; and quote-smuggled
    # mutating flags collapse to their true spelling and are caught.
    {
      'parameter expansion'      => 'echo "$HOME"',
      'command substitution'     => 'echo "$(rm -rf ~)"',
      'backtick substitution'    => 'echo "`rm`"',
      'escaped-quote mis-parse'  => 'echo "a\\"b; rm -rf ~"', # \ rejects before the bait quote
      'harmless-looking escape'  => 'echo "a\\nb"',           # any \ inside "..." not approved
      'dmesg empty-pair clear'   => 'dmesg --""clear',        # → dmesg --clear (wipes buffer)
      'dmesg mid-token clear'    => 'dmesg --cl"e"ar',        # → dmesg --clear
      'git mid-token --output'   => 'git diff --"output"=/x', # → --output (writes a file)
      'quoted command name'      => '"rm" -rf ~',             # → rm, not allowlisted
      'unbalanced double quote'  => 'grep "foo'               # never closes → not approved
    }.each do |label, cmd|
      it "does not approve: #{label} (#{cmd.inspect})" do
        # allow_git so the git guard is actually exercised, not gated off.
        refute described_class.new(allow_git: true).approves?(cmd), "expected no approval for #{cmd.inspect}"
      end
    end
  end

  describe 'edge cases' do
    it 'does not approve a nil command' do
      refute described_class.new.approves?(nil)
    end

    it 'does not approve an empty / whitespace command' do
      refute described_class.new.approves?('   ')
      refute described_class.new.approves?('')
    end
  end
end
