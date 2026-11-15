# frozen_string_literal: true

require 'etc'
require 'fileutils'
require 'socket'
require 'time'
require 'tmpdir'

module Pikuri
  module Demo
    # The IMAP server the demo account syncs from: a rootless dovecot on
    # loopback, up only while the builder indexes. An IMAP folder's +.msf+
    # summary and its UIDs come from the server's replies, and a "reparse"
    # of one means a refetch, so mbox dropped into +ImapMail/+ would be
    # ignored; Thunderbird has to download the mail for real.
    #
    # It serves Maildir, one file per message, not mbox: dovecot's mbox driver
    # rewrites the file to add its own headers, which failed on the
    # CRLF mbox Thunderbird keeps ("Sync failed for mbox"), and Thunderbird
    # took the failed body fetch as success. A Maildir file is never
    # rewritten, and its mtime is the message's IMAP +INTERNALDATE+.
    #
    # Everything — config, the mail, its runtime sockets — sits in one fresh
    # directory under +/tmp+: a socket path can't exceed 108 bytes, which a
    # home or cache path can. Dovecot 2.4 syntax; Ubuntu ships 2.4.
    class Dovecot
      # Loopback port; fixed, since it is in +user.js+ and so in the cache key.
      PORT = 10_143

      # The demo account's login.
      USER = 'alex@novak.example'

      # The second account's, on the same host: Alex's personal address.
      PERSONAL_USER = 'alex.novak@kotiposti.example'

      # The password the static passdb takes; Thunderbird gets it over
      # Marionette, never from a file.
      PASSWORD = 'demo'

      # @param messages [Hash{String => String}] +"<login>/<folder>/<name>"+
      #   to one message's bytes; the folder +INBOX+ is the inbox, a nested
      #   one is +/+-separated (+[Gmail]/All Mail+), and names sort in the
      #   order the UIDs should follow.
      # @return [Dovecot] a running server.
      # @raise [RuntimeError] when the port is taken or dovecot doesn't come up.
      def self.start(messages:)
        new(messages).tap(&:start)
      end

      # @param messages [Hash{String => String}]
      def initialize(messages)
        @messages = messages
      end

      # @return [void]
      def start
        raise "port #{PORT} is taken; the testbed's dovecot needs it" if listening?

        @dir = Dir.mktmpdir('pikuri-dovecot-')
        mail = File.join(@dir, 'mail')
        write_maildir(mail)
        File.write(config, render(mail))
        @pid = Process.spawn('dovecot', '-F', '-c', config, in: File::NULL, out: log, err: %i[child out])
        wait_until_listening
      rescue StandardError
        stop
        raise
      end

      # Stops the server and removes its directory.
      #
      # @return [void]
      def stop
        if @pid
          begin
            Process.kill('TERM', @pid)
            Process.wait(@pid)
          rescue Errno::ESRCH, Errno::ECHILD
            nil
          end
          @pid = nil
        end
        FileUtils.rm_rf(@dir) if @dir
      end

      private

      # @return [String]
      def config = File.join(@dir, 'dovecot.conf')

      # @return [String]
      def log = File.join(@dir, 'dovecot.log')

      # Maildir++, one per login: INBOX is +<login>/cur/+, a folder +Sent+ is
      # +<login>/.Sent/cur/+, +[Gmail]/All Mail+ is +<login>/.[Gmail].All
      # Mail/cur/+. No +:2,+ flag letters, so every message arrives unread.
      #
      # @param mail [String]
      # @return [void]
      def write_maildir(mail)
        @messages.each do |path, bytes|
          login, rest = path.split('/', 2)
          folder, _, name = rest.rpartition('/')
          dir = File.join(mail, login, folder == 'INBOX' ? '' : ".#{folder.tr('/', '.')}")
          %w[cur new tmp].each { FileUtils.mkdir_p(File.join(dir, _1)) }
          file = File.join(dir, 'cur', "#{name}.pikuri-demo:2,")
          File.binwrite(file, bytes)
          date = Time.rfc2822(bytes[/^Date:[ \t]*(.+?)\r?$/i, 1])
          File.utime(date, date, file)
        end
      end

      # @return [Boolean]
      def listening?
        TCPSocket.new('127.0.0.1', PORT).close
        true
      rescue SystemCallError
        false
      end

      # @return [void]
      # @raise [RuntimeError] after 10 s, or when dovecot exits first.
      def wait_until_listening
        deadline = Time.now + 10
        until listening?
          @pid = nil if Process.wait(@pid, Process::WNOHANG)
          if @pid.nil? || Time.now > deadline
            raise "dovecot didn't come up on port #{PORT}:\n#{File.read(log) if File.file?(log)}"
          end

          sleep 0.1
        end
      end

      # Any login with the password gets in, to its own Maildir.
      #
      # Rootless: every internal and login process runs as the caller, the
      # login process isn't chrooted (that needs root), and only the plain
      # IMAP listener is on (+imaps+ would want port 993). Folders nest with
      # +/+, Gmail's separator, so +[Gmail]+ is a non-selectable parent. +Sent+
      # carries the +\Sent+ special-use flag, as Gmail's and iCloud's do, and
      # +[Gmail]/All Mail+ and +[Gmail]/Starred+ Gmail's +\All+ and +\Flagged+.
      #
      # @param mail [String] the directory of the per-login Maildirs.
      # @return [String]
      def render(mail)
        user = Etc.getpwuid(Process.uid).name
        group = Etc.getgrgid(Process.gid).name
        <<~CONF
          dovecot_config_version = 2.4.0
          dovecot_storage_version = 2.4.0
          protocols = imap
          listen = 127.0.0.1
          base_dir = #{@dir}/run
          state_dir = #{@dir}/state
          log_path = #{log}
          default_internal_user = #{user}
          default_internal_group = #{group}
          default_login_user = #{user}
          ssl = no
          auth_allow_cleartext = yes

          passdb static {
            password = #{PASSWORD}
          }
          userdb static {
            fields {
              uid = #{Process.uid}
              gid = #{Process.gid}
              home = #{@dir}/home/%{user}
            }
          }

          mail_driver = maildir
          mail_path = #{mail}/%{user}
          namespace inbox {
            inbox = yes
            separator = /
            mailbox Sent {
              special_use = \\Sent
            }
            mailbox "[Gmail]/All Mail" {
              special_use = \\All
            }
            mailbox "[Gmail]/Starred" {
              special_use = \\Flagged
            }
          }

          service imap-login {
            chroot =
            inet_listener imap {
              port = #{PORT}
            }
            inet_listener imaps {
              port = 0
            }
          }
        CONF
      end
    end
  end
end
