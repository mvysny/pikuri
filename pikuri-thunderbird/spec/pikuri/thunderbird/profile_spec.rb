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
