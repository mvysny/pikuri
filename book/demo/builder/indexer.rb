# frozen_string_literal: true

require 'fileutils'
require 'sqlite3'
require 'tmpdir'

module Pikuri
  module Demo
    # Runs a headless Thunderbird on the demo profile until its stores hold
    # everything the builder wrote, then quits it cleanly.
    #
    # A dropped mbox isn't picked up on its own: with mail checks off nothing
    # opens a folder, so no +.msf+ summary appears and Gloda's sweep skips
    # the folder. So over Marionette every folder is reparsed and then queued
    # for Gloda; +indexFolder+ alone, without the reparse, indexes nothing.
    #
    # Done-detection is by count, not by guessing at Gloda's internals: the
    # builder knows it wrote N messages, so a copy of the Gloda DB is counted
    # until it holds N. The clean quit then checkpoints the calendar's WAL, so
    # the M events become countable in +cache.sqlite+ too.
    class Indexer
      # Reparses every mail folder and queues it for Gloda. Resolves with the
      # folder names, or +{error:}+.
      REPARSE_JS = <<~JS
        const resolve = arguments[arguments.length - 1];
        (async () => {
          const { MailServices } = ChromeUtils.importESModule("resource:///modules/MailServices.sys.mjs");
          const { GlodaMsgIndexer } = ChromeUtils.importESModule("resource:///modules/gloda/IndexMsg.sys.mjs");
          const skip = Ci.nsMsgFolderFlags.Trash | Ci.nsMsgFolderFlags.Queue;
          const done = [];
          for (const account of MailServices.accounts.accounts) {
            for (const folder of account.incomingServer.rootFolder.descendants) {
              if (folder.flags & skip) continue;
              await new Promise((ok, fail) => {
                const listener = {
                  QueryInterface: ChromeUtils.generateQI(["nsIUrlListener"]),
                  OnStartRunningUrl() {},
                  OnStopRunningUrl(url, status) {
                    Components.isSuccessCode(status) ? ok() : fail(new Error(`reparse of ${folder.URI}: ${status}`));
                  },
                };
                try {
                  folder.QueryInterface(Ci.nsIMsgLocalMailFolder).getDatabaseWithReparse(listener, null);
                  ok(); // the summary was already valid
                } catch (e) {
                  if (e.result !== Cr.NS_ERROR_NOT_INITIALIZED) fail(e); // else: reparse started
                }
              });
              GlodaMsgIndexer.indexFolder(folder, { force: true });
              done.push(folder.URI);
            }
          }
          return done;
        })().then(resolve, (e) => resolve({ error: String(e) }));
      JS

      # Asks Thunderbird to quit once the reply is on its way. A clean quit
      # checkpoints the WAL databases.
      QUIT_JS = <<~JS
        const resolve = arguments[arguments.length - 1];
        resolve(true);
        Services.tm.dispatchToMainThread(() => Services.startup.quit(Ci.nsIAppStartup.eAttemptQuit));
      JS

      # Gloda keeps a row per referenced-but-absent message too (a "ghost",
      # +folderID+ null), so only real ones count.
      MESSAGES_SQL = 'SELECT COUNT(*) FROM messages WHERE folderID IS NOT NULL'

      # The demo calendar's events (a recurring one is one row).
      EVENTS_SQL = "SELECT COUNT(*) FROM cal_events WHERE cal_id = 'pikuridemo'"

      # @param profile_dir [String]
      # @param messages [Integer] how many messages the builder wrote.
      # @param events [Integer] how many events the demo calendar holds.
      # @param log [String] where Thunderbird's own output goes.
      # @param timeout [Numeric] seconds to wait for the index.
      def initialize(profile_dir:, messages:, events:, log:, timeout: 300)
        @profile_dir = profile_dir
        @messages = messages
        @events = events
        @log = log
        @timeout = timeout
      end

      # @return [Float] seconds the index took.
      # @raise [RuntimeError] when the index stalls or a count is off.
      def run!
        started = Time.now
        @pid = launch
        marionette = Marionette.connect(port: active_port)
        folders = marionette.execute_async(REPARSE_JS, timeout: 120)
        raise "reparse failed: #{folders['error']}" if folders.is_a?(Hash)

        wait_for_messages
        elapsed = Time.now - started
        marionette.execute_async(QUIT_JS)
        marionette.close
        wait_for_exit
        verify_closed_stores
        elapsed
      ensure
        kill_leftover
      end

      private

      # @return [Integer] pid of the +thunderbird+ launcher.
      def launch
        File.delete(port_file) if File.exist?(port_file)
        env = { 'MOZ_REMOTE_ALLOW_SYSTEM_ACCESS' => '1', 'MOZ_CRASHREPORTER_DISABLE' => '1' }
        Process.spawn(env, 'thunderbird', '--headless', '--marionette', '--no-remote',
                      '-profile', @profile_dir,
                      in: File::NULL, out: @log, err: %i[child out], pgroup: true)
      end

      # @return [String] where Marionette writes the port it picked.
      def port_file = File.join(@profile_dir, 'MarionetteActivePort')

      # @return [Integer] the port Marionette listens on.
      def active_port
        deadline = Time.now + 60
        until File.size?(port_file)
          raise "Thunderbird wrote no #{port_file} in 60s; see #{@log}" if Time.now > deadline
          raise "Thunderbird exited early; see #{@log}" if exited?

          sleep 0.25
        end
        Integer(File.read(port_file).strip)
      end

      # Counts a copy of the Gloda DB until it holds every message.
      #
      # @return [void]
      def wait_for_messages
        deadline = Time.now + @timeout
        last = nil
        loop do
          count = count_copy(File.join(@profile_dir, 'global-messages-db.sqlite'), MESSAGES_SQL)
          if count != last
            puts "  indexed #{count || 0}/#{@messages}"
            last = count
          end
          return if count == @messages
          raise "Gloda holds #{count} messages, expected #{@messages}" if count && count > @messages
          raise "index stalled at #{count || 0}/#{@messages} after #{@timeout}s" if Time.now > deadline

          sleep 1
        end
      end

      # Counts on a private copy, never the file Thunderbird holds open; a
      # copy torn by a write in flight just counts as "not yet".
      #
      # @param db [String]
      # @param sql [String]
      # @return [Integer, nil]
      def count_copy(db, sql)
        return nil unless File.file?(db)

        Dir.mktmpdir('pikuri-demo-count-') do |tmp|
          copy = File.join(tmp, 'db.sqlite')
          FileUtils.cp(db, copy)
          FileUtils.cp("#{db}-wal", "#{copy}-wal") if File.file?("#{db}-wal")
          sqlite = SQLite3::Database.new(copy)
          begin
            sqlite.get_first_value(sql)
          ensure
            sqlite.close
          end
        end
      rescue SQLite3::Exception
        nil
      end

      # @return [void]
      def wait_for_exit
        deadline = Time.now + 30
        sleep 0.25 until exited? || Time.now > deadline
        raise "Thunderbird didn't quit in 30s; see #{@log}" unless exited?
      end

      # @return [Boolean]
      def exited?
        return true if @pid.nil?
        return false unless Process.wait(@pid, Process::WNOHANG)

        @pid = nil
        true
      rescue Errno::ECHILD
        @pid = nil
        true
      end

      # After the clean quit both stores are checkpointed and closed.
      #
      # @return [void]
      def verify_closed_stores
        messages = count_copy(File.join(@profile_dir, 'global-messages-db.sqlite'), MESSAGES_SQL)
        raise "after quit Gloda holds #{messages.inspect} messages, expected #{@messages}" unless messages == @messages

        events = count_copy(File.join(@profile_dir, 'calendar-data', 'cache.sqlite'), EVENTS_SQL)
        raise "after quit the calendar holds #{events.inspect} events, expected #{@events}" unless events == @events
      end

      # @return [void]
      def kill_leftover
        return if exited?

        Process.kill('TERM', -@pid)
        sleep 1
        Process.kill('KILL', -@pid) unless exited?
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
