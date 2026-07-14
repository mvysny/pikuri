# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'

describe Pikuri::Thunderbird::Extension do
  Extension = Pikuri::Thunderbird::Extension

  # Records what an extension wires — the Extension only touches these two.
  class FakeConfigurator
    attr_reader :tools, :closers

    def initialize
      @tools = []
      @closers = []
    end

    def add_tool(tool) = @tools << tool
    def on_close(&blk) = @closers << blk
  end

  def write_gloda(dir)
    db = SQLite3::Database.new(File.join(dir, 'global-messages-db.sqlite'))
    db.execute('CREATE TABLE messagesText_content(docid INTEGER PRIMARY KEY, c0body, c1subject, c2attachmentNames, c3author, c4recipients)')
    db.execute('CREATE TABLE messages(id INTEGER PRIMARY KEY, folderID INTEGER, date INTEGER, headerMessageID TEXT, deleted INTEGER)')
    db.execute('CREATE TABLE folderLocations(id INTEGER PRIMARY KEY, folderURI TEXT, dirtyStatus INTEGER, name TEXT, indexingPriority INTEGER)')
    db.close
  end

  def write_calendar(dir)
    caldir = File.join(dir, 'calendar-data')
    FileUtils.mkdir_p(caldir)
    db = SQLite3::Database.new(File.join(caldir, 'cache.sqlite'))
    db.execute('CREATE TABLE cal_events(cal_id TEXT, id TEXT, title TEXT, event_start INTEGER, event_end INTEGER, event_start_tz TEXT, event_end_tz TEXT, flags INTEGER, ical_status TEXT)')
    db.execute('CREATE TABLE cal_properties(item_id TEXT, key TEXT, value TEXT)')
    db.close
  end

  def tool_names(dir, cache)
    c = FakeConfigurator.new
    Extension.new(profile_dir: dir, cache_dir: cache).configure(c)
    [c, c.tools.map(&:name)]
  end

  it 'wires all four tools when Gloda + a calendar store are present' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      write_calendar(dir)
      Dir.mktmpdir do |cache|
        c, names = tool_names(dir, cache)
        assert_equal %w[thunderbird_mail_search thunderbird_mail_read
                        thunderbird_calendar_search thunderbird_calendar_read].sort,
                     names.sort
        assert_equal 2, c.closers.size, 'mail + calendar each register a closer'
      end
    end
  end

  it 'omits mail tools when Gloda is absent but still wires calendar' do
    Dir.mktmpdir do |dir|
      write_calendar(dir) # no Gloda file
      Dir.mktmpdir do |cache|
        _, names = tool_names(dir, cache)
        refute_includes names, 'thunderbird_mail_search'
        assert_includes names, 'thunderbird_calendar_search'
        assert_includes names, 'thunderbird_calendar_read'
      end
    end
  end

  it 'registers calendar tools even with no calendar store (self-explaining empty state)' do
    Dir.mktmpdir do |dir|
      write_gloda(dir) # profile exists, no calendar-data dir
      Dir.mktmpdir do |cache|
        _, names = tool_names(dir, cache)
        assert_includes names, 'thunderbird_calendar_search'
      end
    end
  end

  it 'registers nothing when Thunderbird is not installed' do
    skip 'a real Thunderbird root exists on this host' if Pikuri::Thunderbird::Profile.discover
    Dir.mktmpdir do |cache|
      c = FakeConfigurator.new
      Extension.new(cache_dir: cache).configure(c) # no profile_dir → auto-discover → nil
      assert_empty c.tools
    end
  end
end
