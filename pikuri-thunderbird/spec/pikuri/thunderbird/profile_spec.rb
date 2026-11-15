# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

describe Pikuri::Thunderbird::Profile do
  Profile = Pikuri::Thunderbird::Profile

  describe '.discover with explicit profile_dir' do
    it 'uses the override verbatim and derives paths' do
      Dir.mktmpdir do |dir|
        profile = Profile.discover(profile_dir: dir)
        assert_equal dir, profile.dir
        assert_equal :override, profile.variant
        assert_equal File.join(dir, 'global-messages-db.sqlite'), profile.gloda_path
        assert_equal File.join(dir, 'calendar-data'), profile.calendar_dir
      end
    end

    it 'raises when the override is not a directory' do
      assert_raises(Profile::DiscoveryError) do
        Profile.discover(profile_dir: '/no/such/dir/here')
      end
    end
  end

  describe '.discover across install roots' do
    around do |example|
      Dir.mktmpdir do |home|
        @home = home
        example.run
      end
    end

    def roots = { snap: File.join(@home, 'snap'), apt: File.join(@home, 'apt') }

    # A root holding one Default=1 profile; +account_type:+ nil writes no prefs.js.
    def make_root(root, account_type: 'imap')
      FileUtils.mkdir_p(File.join(root, 'p.default'))
      File.write(File.join(root, 'profiles.ini'), "[Profile0]\nPath=p.default\nIsRelative=1\nDefault=1\n")
      return unless account_type

      File.write(File.join(root, 'p.default', 'prefs.js'), <<~JS)
        user_pref("mail.server.server1.type", "none");
        user_pref("mail.server.server2.type", "#{account_type}");
      JS
    end

    it 'returns nil when no root holds a profiles.ini' do
      assert_nil Profile.discover(roots: roots)
    end

    it 'finds the one root that holds a profile' do
      make_root(roots[:apt])
      profile = Profile.discover(roots: roots)
      assert_equal File.join(roots[:apt], 'p.default'), profile.dir
      assert_equal :apt, profile.variant
    end

    it 'treats a snap root symlinked to the apt root as one profile' do
      make_root(roots[:apt])
      File.symlink(roots[:apt], roots[:snap])
      profile = Profile.discover(roots: roots)
      assert_equal :snap, profile.variant
      assert profile.mail_account?
    end

    it 'skips a profile with no mail account' do
      make_root(roots[:snap], account_type: 'none')
      make_root(roots[:apt])
      assert_equal :apt, Profile.discover(roots: roots).variant
    end

    it 'picks the first root when no profile has a mail account' do
      make_root(roots[:snap], account_type: nil)
      make_root(roots[:apt], account_type: 'none')
      assert_equal :snap, Profile.discover(roots: roots).variant
    end

    it 'raises when two roots hold a profile with a mail account' do
      make_root(roots[:snap])
      make_root(roots[:apt], account_type: 'pop3')
      error = assert_raises(Profile::DiscoveryError) { Profile.discover(roots: roots) }
      assert_includes error.message, roots[:apt]
    end
  end

  describe 'derived presence probes' do
    it 'reports gloda? and calendar_dbs from disk' do
      Dir.mktmpdir do |dir|
        profile = Profile.discover(profile_dir: dir)
        refute profile.gloda?, 'no Gloda file yet'
        assert_empty profile.calendar_dbs

        File.write(profile.gloda_path, '')
        FileUtils.mkdir_p(profile.calendar_dir)
        File.write(profile.calendar_cache_db, '')

        assert profile.gloda?
        assert_equal [profile.calendar_cache_db], profile.calendar_dbs
      end
    end
  end

  describe '#outbox_dir' do
    it 'stages under the profile dir for an override (unconfined)' do
      Dir.mktmpdir do |dir|
        profile = Profile.discover(profile_dir: dir)
        assert_equal File.join(dir, 'pikuri-outbox'), profile.outbox_dir
      end
    end

    it 'stages in the snap-owned data area for a snap profile (dotfile-safe)' do
      profile = Profile.new(dir: '/home/x/snap/thunderbird/common/.thunderbird/p', variant: :snap)
      # The snap `home` interface can't read hidden ~/.cache, but the snap's own
      # common area is always readable — so we stage one level up from SNAP_ROOT.
      assert_equal File.join(File.dirname(Profile::SNAP_ROOT), 'pikuri-outbox'), profile.outbox_dir
    end
  end

  describe 'profiles.ini resolution' do
    def write_ini(root, body)
      File.write(File.join(root, 'profiles.ini'), body)
    end

    it 'resolves the Default=1 relative profile' do
      Dir.mktmpdir do |root|
        write_ini(root, <<~INI)
          [Profile0]
          Name=default
          IsRelative=1
          Path=ql3rk8ye.default
          Default=1

          [General]
          StartWithLastProfile=1
        INI
        resolved = Profile.send(:resolve_within, root)
        assert_equal File.join(root, 'ql3rk8ye.default'), resolved
      end
    end

    it 'uses the sole profile when none is marked default' do
      Dir.mktmpdir do |root|
        write_ini(root, "[Profile0]\nPath=only.default\nIsRelative=1\n")
        assert_equal File.join(root, 'only.default'), Profile.send(:resolve_within, root)
      end
    end

    it 'raises on several profiles with no Default=1' do
      Dir.mktmpdir do |root|
        write_ini(root, <<~INI)
          [Profile0]
          Name=one
          Path=one.default
          [Profile1]
          Name=two
          Path=two.default
        INI
        assert_raises(Profile::DiscoveryError) { Profile.send(:resolve_within, root) }
      end
    end

    it 'honors IsRelative=0 as an absolute path' do
      Dir.mktmpdir do |root|
        write_ini(root, "[Profile0]\nPath=/abs/profile\nIsRelative=0\nDefault=1\n")
        assert_equal '/abs/profile', Profile.send(:resolve_within, root)
      end
    end
  end
end
