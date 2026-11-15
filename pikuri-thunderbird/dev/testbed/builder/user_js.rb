# frozen_string_literal: true

require 'json'

module Pikuri
  module Demo
    # The demo profile's +user.js+: the account Thunderbird builds its stores
    # for, and the prefs that keep a first run quiet. Thunderbird reads it at
    # every start and folds it into its own +prefs.js+.
    #
    # The account is IMAP, like most real ones (the owner's Gmail and iCloud
    # among them), syncing from {Dovecot} on loopback; its offline store lands
    # under +ImapMail/127.0.0.1/+. Its login is an address, as Gmail's is, so
    # its folder URIs carry the +%40+ a real one does. Local Folders holds an
    # archive, so the +Mail/+ store is real too. Outside a build nothing
    # listens on the port, so the account never checks mail on its own; the
    # SMTP host is RFC 2606-reserved, so a Send clicked by mistake fails.
    module UserJs
      # Where {Dovecot} listens; also the IMAP store's directory name.
      IMAP_HOST = '127.0.0.1'

      # Stands in for Mozilla's own servers in the quiet prefs' URLs.
      DUMMY_HOST = 'pikuri-dummy.invalid'

      # The quiet-first-run prefs, picked from Marionette's own
      # +RecommendedPreferences.sys.mjs+ (in Thunderbird's +omni.ja+, under
      # +chrome/remote/content/shared/+) — Mozilla's list for keeping an
      # automated profile off the network — plus Thunderbird's own first-run
      # dialogs. Marionette applies its list itself when it starts, but a
      # developer opening the profile without Marionette gets only these.
      QUIET = {
        # Remote settings: the first-run fetch the probe caught.
        'services.settings.server' => 'data:,#remote-settings-dummy/v1',
        'services.settings.loglevel' => 'off',
        'security.remote_settings.intermediates.enabled' => false,
        # Telemetry and data reporting.
        'toolkit.telemetry.enabled' => false,
        'toolkit.telemetry.server' => "https://#{DUMMY_HOST}/telemetry-dummy/",
        'telemetry.fog.test.localhost_port' => -1,
        'datareporting.policy.dataSubmissionEnabled' => false,
        'datareporting.policy.dataSubmissionPolicyBypassNotification' => true,
        'datareporting.healthreport.uploadEnabled' => false,
        'datareporting.healthreport.service.enabled' => false,
        'datareporting.usage.uploadEnabled' => false,
        'app.normandy.api_url' => '',
        # Updates of the app, add-ons, search engines, the user agent.
        'app.update.disabledForTesting' => true,
        'extensions.update.enabled' => false,
        'extensions.update.notifyUser' => false,
        'extensions.update.url' => "http://#{DUMMY_HOST}/extensions-dummy/updateURL",
        'extensions.update.background.url' => "http://#{DUMMY_HOST}/extensions-dummy/updateBackgroundURL",
        'extensions.systemAddon.update.enabled' => false,
        'extensions.getAddons.cache.enabled' => false,
        'extensions.getAddons.discovery.api_url' => 'data:, ',
        'extensions.blocklist.detailsURL' => "http://#{DUMMY_HOST}/extensions-dummy/blocklistDetailsURL",
        'extensions.blocklist.itemURL' => "http://#{DUMMY_HOST}/extensions-dummy/blocklistItemURL",
        'browser.search.update' => false,
        'general.useragent.updates.enabled' => false,
        # Background network services.
        'network.captive-portal-service.enabled' => false,
        'network.connectivity-service.enabled' => false,
        'network.sntp.pools' => DUMMY_HOST,
        'dom.push.connection.enabled' => false,
        'browser.region.network.url' => '',
        'geo.provider.network.url' => '',
        'browser.safebrowsing.blockedURIs.enabled' => false,
        'browser.safebrowsing.downloads.enabled' => false,
        'browser.safebrowsing.malware.enabled' => false,
        'browser.safebrowsing.phishing.enabled' => false,
        # Thunderbird's own first run: no account wizard or provisioner, no
        # start page, no donation tab, no default-client check.
        'mail.provider.enabled' => false,
        'mail.provider.suppress_dialog_on_startup' => true,
        'mailnews.start_page.enabled' => false,
        'mail.shell.checkDefaultClient' => false,
        'mail.rights.version' => 1,
        'app.donation.eoy.version.viewed' => 999
      }.freeze

      # @param ics_path [String] absolute path of the demo calendar file.
      # @return [String] the +user.js+ text.
      def self.render(ics_path:)
        prefs = account_prefs.merge(calendar_prefs(ics_path)).merge(QUIET).merge(
          # Gloda on, and Marionette on a free port it writes to
          # +MarionetteActivePort+ in the profile (port 0), so a build never
          # collides with another Thunderbird's 2828.
          'mailnews.database.global.indexer.enabled' => true,
          'marionette.port' => 0
        )
        prefs.map { |name, value| "user_pref(#{JSON.generate(name)}, #{JSON.generate(value)});\n" }.join
      end

      # @return [Hash{String => Object}]
      def self.account_prefs
        imap = "imap://#{Dovecot::USER.sub('@', '%40')}@#{IMAP_HOST}"
        {
          'mail.accountmanager.accounts' => 'account1,account2',
          'mail.accountmanager.defaultaccount' => 'account1',
          'mail.accountmanager.localfoldersserver' => 'server2',
          'mail.account.account1.identities' => 'id1',
          'mail.account.account1.server' => 'server1',
          'mail.account.account2.server' => 'server2',
          'mail.identity.id1.fullName' => 'Alex Novak',
          'mail.identity.id1.useremail' => 'alex@novak.example',
          'mail.identity.id1.smtpServer' => 'smtp1',
          'mail.identity.id1.valid' => true,
          'mail.identity.id1.fcc_folder' => "#{imap}/Sent",
          'mail.server.server1.type' => 'imap',
          'mail.server.server1.hostname' => IMAP_HOST,
          'mail.server.server1.port' => Dovecot::PORT,
          'mail.server.server1.userName' => Dovecot::USER,
          'mail.server.server1.name' => 'alex@novak.example',
          'mail.server.server1.directory-rel' => "[ProfD]ImapMail/#{IMAP_HOST}",
          'mail.server.server1.socketType' => 0, # plain: loopback, and dovecot has no certificate
          'mail.server.server1.authMethod' => 3, # cleartext password
          # Every folder, not only subscribed ones: nothing subscribes on a
          # fresh dovecot.
          'mail.server.server1.using_subscription' => false,
          # The build syncs and downloads itself; afterwards there is no server.
          'mail.server.server1.login_at_startup' => false,
          'mail.server.server1.check_new_mail' => false,
          'mail.server.server1.autosync_offline_stores' => false,
          'mail.server.server2.type' => 'none',
          'mail.server.server2.hostname' => 'Local Folders',
          'mail.server.server2.userName' => 'nobody',
          'mail.server.server2.name' => 'Local Folders',
          'mail.server.server2.directory-rel' => '[ProfD]Mail/Local Folders',
          'mail.smtpservers' => 'smtp1',
          'mail.smtp.defaultserver' => 'smtp1',
          'mail.smtpserver.smtp1.hostname' => 'smtp.novak.example',
          'mail.smtpserver.smtp1.port' => 587,
          'mail.smtpserver.smtp1.username' => 'alex'
        }
      end
      private_class_method :account_prefs

      # An +ics+ network calendar with the cache on, so Thunderbird syncs the
      # file into +calendar-data/cache.sqlite+ — the store pikuri reads.
      #
      # @param ics_path [String]
      # @return [Hash{String => Object}]
      def self.calendar_prefs(ics_path)
        {
          'calendar.registry.pikuridemo.type' => 'ics',
          'calendar.registry.pikuridemo.uri' => "file://#{ics_path}",
          'calendar.registry.pikuridemo.name' => 'Alex',
          'calendar.registry.pikuridemo.cache.enabled' => true,
          'calendar.registry.pikuridemo.readOnly' => false,
          'calendar.list.sortOrder' => 'pikuridemo'
        }
      end
      private_class_method :calendar_prefs
    end
  end
end
