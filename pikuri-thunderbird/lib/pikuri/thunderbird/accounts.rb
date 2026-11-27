# frozen_string_literal: true

require 'json'
require 'uri'

module Pikuri
  module Thunderbird
    # The account graph in +prefs.js+, the only file that says which server
    # holds a folder and which of the user's own addresses each account sends
    # from:
    #
    #   accounts = Accounts.read(profile)
    #   accounts.server_for('imap://alex%40novak.example@127.0.0.1/INBOX')
    #   # => {"type"=>"imap", "directory-rel"=>"[ProfD]ImapMail/127.0.0.1", …}
    #   accounts.identities.map(&:email)  # => ["alex@novak.example", "alex.novak@kotiposti.example"]
    #   accounts.identities_for('imap://alex.novak%40kotiposti.example@127.0.0.1/INBOX').first.email
    #   # => "alex.novak@kotiposti.example"
    #
    # A fresh read per call, so an account added while pikuri runs is seen.
    # Reads only the +mail.server.*+, +mail.account.*+, +mail.identity.*+ and
    # +mail.accountmanager.defaultaccount+ lines; passwords live in
    # +logins.json+, never here.
    #
    # == Implementation details
    #
    # A folder is matched to its server by +[scheme, userName, hostname]+,
    # the scheme +imap+ for IMAP and +mailbox+ for local stores. Gloda's
    # folder URIs are not valid RFC 3986 (raw +[Gmail]+ brackets and spaces),
    # so they are split by regex. Each server sits under +serverN+, and
    # +mail.account.accountN.server+ names the account that owns it.
    #
    # Immutable.
    class Accounts
      # One of the user's own sending addresses.
      #
      # * +email+ — +String+, as +prefs.js+ spells it.
      # * +name+ — +String+, the display name; empty when unset.
      Identity = Data.define(:email, :name)

      # @return [Regexp] one +mail.server+ / +account+ / +identity+ pref line.
      PREF = /\Auser_pref\("mail\.(server|account|identity)\.(\w+)\.([^"]+)",\s*(.*)\);\s*\z/

      # @param profile [Profile]
      # @return [Accounts]
      def self.read(profile)
        prefs = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = {} } }
        default = nil
        if File.file?(profile.prefs_path)
          File.foreach(profile.prefs_path, encoding: 'UTF-8') do |line|
            if (m = line.match(PREF))
              prefs[m[1]][m[2]][m[3]] = JSON.parse(m[4])
            elsif (d = line[/\Auser_pref\("mail\.accountmanager\.defaultaccount",\s*(".*")\);/, 1])
              default = JSON.parse(d)
            end
          end
        end
        new(servers: prefs['server'], accounts: prefs['account'], identities: prefs['identity'], default:)
      end

      # @param servers [Hash{String => Hash{String => Object}}] +serverN+ → its prefs.
      # @param accounts [Hash{String => Hash{String => Object}}] +accountN+ → its prefs.
      # @param identities [Hash{String => Hash{String => Object}}] +idN+ → its prefs.
      # @param default [String, nil] the default +accountN+.
      # @return [Accounts]
      def initialize(servers:, accounts:, identities:, default:)
        @servers = servers
        @accounts = accounts
        @identities = identities
        @default = default
      end

      # @param folder_uri [String] a Gloda +folderURI+, e.g.
      #   +"imap://me%40gmail.com@imap.gmail.com/[Gmail]/All Mail"+.
      # @return [Hash{String => Object}, nil] the owning server's prefs
      #   (+type+, +directory-rel+, +storeContractID+, …), or +nil+ when no
      #   account owns the folder.
      def server_for(folder_uri)
        key = server_key(folder_uri)
        key && @servers[key]
      end

      # @return [Array<Identity>] every account's identities, in account order.
      def identities
        @accounts.each_value.flat_map { identities_of(_1) }.uniq
      end

      # The identities of the account that owns +folder_uri+, its default
      # first; a folder of an account with none (Local Folders) gets the
      # default account's, as Thunderbird answers from it.
      #
      # @param folder_uri [String] a Gloda +folderURI+.
      # @return [Array<Identity>] empty when no account sends from there.
      def identities_for(folder_uri)
        key = server_key(folder_uri)
        own = @accounts.each_value.find { key && _1['server'] == key }
        found = own ? identities_of(own) : []
        found.empty? && @default ? identities_of(@accounts[@default]) : found
      end

      private

      # @return [String, nil] the +serverN+ owning +folder_uri+.
      def server_key(folder_uri)
        m = folder_uri.to_s.match(%r{\A(\w+)://([^@/]+)@([^/]+)/}) or return nil
        scheme, user, host = m.captures.map { URI.decode_uri_component(_1) }
        @servers.each_key.find do |key|
          s = @servers[key]
          [s['type'] == 'imap' ? 'imap' : 'mailbox', s['userName'], s['hostname']] == [scheme, user, host]
        end
      end

      # @param account [Hash{String => Object}, nil] one +accountN+'s prefs.
      # @return [Array<Identity>]
      def identities_of(account)
        account.to_h['identities'].to_s.split(',').filter_map do |id|
          email = @identities.dig(id.strip, 'useremail')
          Identity.new(email:, name: @identities.dig(id.strip, 'fullName').to_s) if email && !email.empty?
        end
      end
    end
  end
end
