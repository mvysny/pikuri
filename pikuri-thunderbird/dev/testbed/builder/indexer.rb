# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'sqlite3'
require 'tmpdir'

module Pikuri
  module Demo
    # Runs a headless Thunderbird on the demo profile until its stores hold
    # everything the builder wrote, then quits it cleanly.
    #
    # The IMAP account first syncs from {Dovecot}: its folders are listed,
    # each one's headers fetched (which writes its +.msf+) and its bodies
    # downloaded into the offline store, all over Marionette, since with mail
    # checks off nothing would connect on its own.
    #
    # A dropped mbox in Local Folders isn't picked up on its own either:
    # nothing opens the folder, so no +.msf+ summary appears and Gloda's sweep
    # skips it. So it is reparsed, and then every folder is queued for Gloda;
    # +indexFolder+ alone, without the reparse, indexes nothing.
    #
    # Done-detection is by count, not by guessing at Gloda's internals: the
    # builder knows it wrote N messages, so a copy of the Gloda DB is counted
    # until it holds N. The clean quit then checkpoints the calendar's WAL, so
    # the M events become countable in +cache.sqlite+ too.
    class Indexer
      # Syncs the IMAP folders, reparses the local ones, and queues every
      # folder for Gloda. Resolves with the folder URIs, or +{error:}+.
      SYNC_JS = <<~JS
        const resolve = arguments[arguments.length - 1];
        (async () => {
          const { MailServices } = ChromeUtils.importESModule("resource:///modules/MailServices.sys.mjs");
          const { GlodaMsgIndexer } = ChromeUtils.importESModule("resource:///modules/gloda/IndexMsg.sys.mjs");
          const skip = Ci.nsMsgFolderFlags.Trash | Ci.nsMsgFolderFlags.Queue;
          // Runs one URL-based operation; start(listener) kicks it off.
          const run = (what, start) => new Promise((ok, fail) => {
            start({
              QueryInterface: ChromeUtils.generateQI(["nsIUrlListener"]),
              OnStartRunningUrl() {},
              OnStopRunningUrl(url, status) {
                Components.isSuccessCode(status) ? ok() : fail(new Error(`${what}: ${status}`));
              },
            });
          });
          const reparse = (folder) => new Promise((ok, fail) => {
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
          const done = [];
          for (const account of MailServices.accounts.accounts) {
            const server = account.incomingServer;
            const imap = server.type === "imap";
            if (imap) {
              server.password = #{Dovecot::PASSWORD.to_json};
              await run("folder discovery", (l) => MailServices.imap.discoverAllFolders(server.rootFolder, l, null));
            }
            for (const folder of server.rootFolder.descendants) {
              if (folder.flags & skip) continue;
              if (imap) {
                // What the account wizard's "keep messages on this computer"
                // sets; an account from user.js lacks it on INBOX, made before
                // the folders were discovered.
                folder.setFlag(Ci.nsMsgFolderFlags.Offline);
                // Selects the folder, syncs its headers and fetches every body.
                // A separate updateFolderWithListener first is worse than
                // useless: its listener heard the discovery URL end, and the
                // download then found the folder busy and fetched nothing.
                await run(`download of ${folder.URI}`, (l) => folder.downloadAllForOffline(l, null));
                let missing = 0;
                for (const hdr of folder.msgDatabase.enumerateMessages()) {
                  if (!(hdr.flags & Ci.nsMsgMessageFlags.Offline)) missing++;
                }
                if (missing) throw new Error(`${missing} bodies of ${folder.URI} weren't downloaded`);
              } else {
                await reparse(folder);
              }
              GlodaMsgIndexer.indexFolder(folder, { force: true });
              done.push(folder.URI);
            }
          }
          return done;
        })().then(resolve, (e) => resolve({ error: String(e) }));
      JS


      # Gloda keeps a row per referenced-but-absent message too (a "ghost",
      # +folderID+ null), so only real ones count; and only with a body, since
      # an IMAP message Gloda reached before its body was downloaded is
      # indexed from its headers alone.
      MESSAGES_SQL = <<~SQL
        SELECT COUNT(*) FROM messages m JOIN messagesText_content t ON t.docid = m.id
        WHERE m.folderID IS NOT NULL AND length(t.c0body) > 0
      SQL

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
        session = Session.start(profile_dir: @profile_dir, log: @log)
        folders = session.execute(SYNC_JS, timeout: 120)
        raise "sync failed: #{folders['error']}" if folders.is_a?(Hash)

        puts "  synced #{folders.join(', ')}"

        wait_for_messages
        elapsed = Time.now - started
        session.quit
        verify_closed_stores
        elapsed
      ensure
        session&.kill
      end

      private

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

      # After the clean quit both stores are checkpointed and closed.
      #
      # @return [void]
      def verify_closed_stores
        messages = count_copy(File.join(@profile_dir, 'global-messages-db.sqlite'), MESSAGES_SQL)
        raise "after quit Gloda holds #{messages.inspect} messages, expected #{@messages}" unless messages == @messages

        events = count_copy(File.join(@profile_dir, 'calendar-data', 'cache.sqlite'), EVENTS_SQL)
        raise "after quit the calendar holds #{events.inspect} events, expected #{@events}" unless events == @events
      end
    end
  end
end
