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
    # checks off nothing would connect on its own. A headers-only folder gets
    # its headers and no bodies, as one never marked for offline use does.
    #
    # A dropped mbox in Local Folders isn't picked up on its own either:
    # nothing opens the folder, so no +.msf+ summary appears and Gloda's sweep
    # skips it. So it is reparsed, and then every folder is queued for Gloda;
    # +indexFolder+ alone, without the reparse, indexes nothing.
    #
    # Done-detection is by count, not by guessing at Gloda's internals: the
    # builder knows it wrote N message copies, B of them in folders whose
    # bodies are downloaded, so a copy of the Gloda DB is counted until it
    # holds N rows, B with a body. The clean quit then checkpoints the
    # calendar's WAL, so the M events become countable in +cache.sqlite+ too.
    #
    # A dropped scene's copies then leave the offline store, after the
    # index: the store's own +deleteMessages+ marks each expunged in its
    # mbox, and Gloda, which listens to folders and not to the store, keeps
    # its row and body. That is pikuri's "not stored on this computer".
    class Indexer
      # Syncs the IMAP folders, reparses the local ones, and queues every
      # folder for Gloda. Needs +imapFolders+ declared before it: each IMAP
      # folder, as +<login>/<server name>+, to +{count:, headersOnly:}+.
      # Resolves with the folder URIs, or +{error:}+.
      SYNC_JS = <<~JS
        const resolve = arguments[arguments.length - 1];
        (async () => {
          const { MailServices } = ChromeUtils.importESModule("resource:///modules/MailServices.sys.mjs");
          const { GlodaMsgIndexer } = ChromeUtils.importESModule("resource:///modules/gloda/IndexMsg.sys.mjs");
          const { setTimeout } = ChromeUtils.importESModule("resource://gre/modules/Timer.sys.mjs");
          // A non-selectable folder (Gmail's [Gmail]) has no messages to sync.
          const skip = Ci.nsMsgFolderFlags.Trash | Ci.nsMsgFolderFlags.Queue | Ci.nsMsgFolderFlags.ImapNoselect;
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
          const headers = (folder) => [...folder.msgDatabase.enumerateMessages()];
          const offline = (hdr) => hdr.flags & Ci.nsMsgMessageFlags.Offline;
          // Runs step until the folder holds the headers the builder wrote,
          // and done(headers). A sync's listener can hear an earlier URL end,
          // and the step then finds the folder busy and does nothing, without
          // an error; so the folder itself is checked, and the step retried.
          const settle = async (folder, expected, step, done) => {
            const deadline = Date.now() + 60000;
            for (;;) {
              await step();
              const hdrs = headers(folder);
              if (hdrs.length >= expected && done(hdrs)) return;
              if (Date.now() > deadline) {
                throw new Error(`${folder.URI} holds ${hdrs.length}/${expected} headers, ` +
                                `${hdrs.filter(offline).length} with a body`);
              }
              await new Promise((ok) => setTimeout(ok, 500));
            }
          };
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
              const spec = imap
                ? imapFolders[`${server.username}/${folder.QueryInterface(Ci.nsIMsgImapMailFolder).onlineName}`]
                : undefined;
              const expected = spec?.count ?? 0;
              if (spec?.headersOnly) {
                // Clears what discovery set from the server's
                // offline_download, as unticking "Select this folder for
                // offline use" does, and syncs the headers alone.
                folder.clearFlag(Ci.nsMsgFolderFlags.Offline);
                await settle(folder, expected,
                             () => run(`header sync of ${folder.URI}`, (l) => folder.updateFolderWithListener(null, l)),
                             () => true);
                if (headers(folder).some(offline)) throw new Error(`${folder.URI} got bodies, but is synced headers-only`);
              } else if (imap) {
                // What the account wizard's "keep messages on this computer"
                // sets; an account from user.js lacks it on INBOX, made before
                // the folders were discovered.
                folder.setFlag(Ci.nsMsgFolderFlags.Offline);
                // Selects the folder, syncs its headers and fetches every body.
                // A separate updateFolderWithListener first is worse than
                // useless: the download then found the folder busy.
                await settle(folder, expected,
                             () => run(`download of ${folder.URI}`, (l) => folder.downloadAllForOffline(l, null)),
                             (hdrs) => hdrs.every(offline));
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


      # Deletes the dropped messages' copies from the offline store. Needs
      # +dropped+ declared before it: their Message-IDs. Resolves with
      # +[{id:, path:}]+, one per copy, the path its folder's mbox; or
      # +{error:}+.
      DROP_JS = <<~JS
        const resolve = arguments[arguments.length - 1];
        (async () => {
          const { MailServices } = ChromeUtils.importESModule("resource:///modules/MailServices.sys.mjs");
          const copies = [];
          for (const account of MailServices.accounts.accounts) {
            for (const folder of account.incomingServer.rootFolder.descendants) {
              if (folder.flags & Ci.nsMsgFolderFlags.ImapNoselect) continue;
              for (const hdr of folder.msgDatabase.enumerateMessages()) {
                if (!dropped.includes(hdr.messageId) || !(hdr.flags & Ci.nsMsgMessageFlags.Offline)) continue;
                folder.msgStore.deleteMessages([hdr]);
                copies.push({ id: hdr.messageId, path: folder.filePath.path });
              }
            }
          }
          return copies;
        })().then(resolve, (e) => resolve({ error: String(e) }));
      JS

      # Gloda's rows, and those with a body. It keeps a row per
      # referenced-but-absent message too (a "ghost", +folderID+ null), so only
      # real ones count. An IMAP message whose body isn't offline is indexed
      # from its headers alone: forever in a headers-only folder, and for a
      # while in the others, if Gloda reaches it before its body.
      MESSAGES_SQL = <<~SQL
        SELECT COUNT(*), COUNT(CASE WHEN length(t.c0body) > 0 THEN 1 END)
        FROM messages m JOIN messagesText_content t ON t.docid = m.id
        WHERE m.folderID IS NOT NULL
      SQL

      # The demo calendar's events (a recurring one is one row).
      EVENTS_SQL = "SELECT COUNT(*) FROM cal_events WHERE cal_id = 'pikuridemo'"

      # @param profile_dir [String]
      # @param messages [Integer] how many message copies the builder wrote.
      # @param imap_folders [Hash{String => Integer}] each IMAP folder, as
      #   +<login>/<server name>+ (+alex@novak.example/[Gmail]/All Mail+), to
      #   how many copies it holds.
      # @param headers_only [Array<String>] the keys of +imap_folders+ synced
      #   without bodies.
      # @param dropped [Array<String>] the Message-IDs whose copies leave the
      #   offline store after the index.
      # @param events [Integer] how many events the demo calendar holds.
      # @param log [String] where Thunderbird's own output goes.
      # @param timeout [Numeric] seconds to wait for the index.
      def initialize(profile_dir:, messages:, imap_folders:, headers_only:, dropped:, events:, log:, timeout: 300)
        @profile_dir = profile_dir
        @dropped = dropped
        @imap_folders = imap_folders.to_h do |key, count|
          [key, { count: count, headersOnly: headers_only.include?(key) }]
        end
        @expected = [messages, messages - imap_folders.slice(*headers_only).values.sum]
        @events = events
        @log = log
        @timeout = timeout
      end

      # @return [Float] seconds the index took.
      # @raise [RuntimeError] when the index stalls or a count is off.
      def run!
        started = Time.now
        session = Session.start(profile_dir: @profile_dir, log: @log)
        folders = session.execute("const imapFolders = #{@imap_folders.to_json};\n#{SYNC_JS}", timeout: 120)
        raise "sync failed: #{folders['error']}" if folders.is_a?(Hash)

        puts "  synced #{folders.join(', ')}"

        wait_for_messages
        copies = drop(session)
        elapsed = Time.now - started
        session.quit
        verify_closed_stores
        verify_dropped(copies)
        elapsed
      ensure
        session&.kill
      end

      private

      # Counts a copy of the Gloda DB until it holds every copy, each body
      # included.
      #
      # @return [void]
      def wait_for_messages
        deadline = Time.now + @timeout
        last = nil
        loop do
          counts = count_copy(File.join(@profile_dir, 'global-messages-db.sqlite'), MESSAGES_SQL)
          if counts != last
            puts "  indexed #{describe(counts)}"
            last = counts
          end
          return if counts == @expected
          raise "Gloda holds #{describe(counts)}" if counts && counts.first > @expected.first
          raise "index stalled at #{describe(counts)} after #{@timeout}s" if Time.now > deadline

          sleep 1
        end
      end

      # @param session [Session]
      # @return [Array<Hash>] +{"id", "path"}+ per dropped copy.
      # @raise [RuntimeError] when a dropped message has no offline copy.
      def drop(session)
        return [] if @dropped.empty?

        copies = session.execute("const dropped = #{@dropped.to_json};\n#{DROP_JS}")
        raise "dropping failed: #{copies['error']}" if copies.is_a?(Hash)

        missing = @dropped - copies.map { _1['id'] }
        raise "no offline copy to drop of #{missing.join(', ')}" unless missing.empty?

        puts "  dropped #{copies.size} offline #{copies.size == 1 ? 'copy' : 'copies'}"
        copies
      end

      # After the quit, each dropped copy carries +X-Mozilla-Status+'s
      # expunged bit in its mbox, as pikuri's +MessageStore+ reads it.
      #
      # @param copies [Array<Hash>] from {#drop}.
      # @return [void]
      # @raise [RuntimeError] when one doesn't.
      def verify_dropped(copies)
        copies.each do |copy|
          mbox = File.binread(copy['path'])
          at = mbox.index(/^Message-ID:[ \t]*<#{Regexp.escape(copy['id'].b)}>/i) or
            raise "#{copy['id']} is gone from #{copy['path']}, not marked expunged"
          start = mbox.rindex(/^From - /, at) || 0
          status = mbox.byteslice(start, at - start)[/^X-Mozilla-Status:[ \t]*(\h+)/i, 1]
          raise "#{copy['id']} in #{copy['path']} isn't marked expunged" unless status&.hex&.anybits?(0x0008)
        end
      end

      # @param counts [Array(Integer, Integer), nil] rows and rows with a body.
      # @return [String] e.g. "12/197 rows, 10/194 with a body".
      def describe(counts)
        rows, bodies = counts || [0, 0]
        "#{rows}/#{@expected.first} rows, #{bodies}/#{@expected.last} with a body"
      end

      # Counts on a private copy, never the file Thunderbird holds open; a
      # copy torn by a write in flight just counts as "not yet".
      #
      # @param db [String]
      # @param sql [String]
      # @return [Array<Integer>, nil] the first row.
      def count_copy(db, sql)
        return nil unless File.file?(db)

        Dir.mktmpdir('pikuri-demo-count-') do |tmp|
          copy = File.join(tmp, 'db.sqlite')
          FileUtils.cp(db, copy)
          FileUtils.cp("#{db}-wal", "#{copy}-wal") if File.file?("#{db}-wal")
          sqlite = SQLite3::Database.new(copy)
          begin
            sqlite.get_first_row(sql)
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
        counts = count_copy(File.join(@profile_dir, 'global-messages-db.sqlite'), MESSAGES_SQL)
        raise "after quit Gloda holds #{describe(counts)}" unless counts == @expected

        events = count_copy(File.join(@profile_dir, 'calendar-data', 'cache.sqlite'), EVENTS_SQL)&.first
        raise "after quit the calendar holds #{events.inspect} events, expected #{@events}" unless events == @events
      end
    end
  end
end
