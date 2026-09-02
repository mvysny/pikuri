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

  it 'wires all inbound tools when Gloda + a calendar store are present' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      write_calendar(dir)
      Dir.mktmpdir do |cache|
        c, names = tool_names(dir, cache)
        assert_equal %w[thunderbird_mail_search thunderbird_mail_read
                        thunderbird_contact_search
                        thunderbird_calendar_search thunderbird_calendar_read].sort,
                     names.sort
        assert_equal 2, c.closers.size, 'mail + calendar each register a closer'
      end
    end
  end

  it 'wires only the mail tools when surfaces: %i[mail]' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      write_calendar(dir)
      Dir.mktmpdir do |cache|
        c = FakeConfigurator.new
        ext = Extension.new(profile_dir: dir, cache_dir: cache, surfaces: %i[mail])
        ext.configure(c)
        assert_equal %w[thunderbird_mail_search thunderbird_mail_read].sort,
                     c.tools.map(&:name).sort
        assert_equal 1, c.closers.size, 'no calendar backend was opened'
        assert ext.mail_wired?
      end
    end
  end

  # The case a knob added without a spec gets wrong quietly: #configure
  # discovers a profile and wires per surface, so a mail-only host on a box
  # with no Gloda index must end up with *nothing* — not a bare calendar.
  it 'wires nothing when the only requested surface has no store' do
    Dir.mktmpdir do |dir|
      write_calendar(dir) # profile + calendar, no Gloda file
      Dir.mktmpdir do |cache|
        c = FakeConfigurator.new
        ext = Extension.new(profile_dir: dir, cache_dir: cache, surfaces: %i[mail])
        ext.configure(c)
        assert_empty c.tools
        refute ext.mail_wired?
        assert_empty ext.system_prompt_snippets, 'nothing wired ⇒ nothing claimed'
      end
    end
  end

  it 'reports mail_wired? false when mail was not requested, index or no index' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      Dir.mktmpdir do |cache|
        ext = Extension.new(profile_dir: dir, cache_dir: cache, surfaces: %i[contacts])
        ext.configure(FakeConfigurator.new)
        refute ext.mail_wired?
      end
    end
  end

  it 'raises on an unknown surface name rather than narrowing silently' do
    Dir.mktmpdir do |cache|
      err = assert_raises(ArgumentError) { Extension.new(cache_dir: cache, surfaces: %i[mail mailbox]) }
      assert_match(/mailbox/, err.message)
    end
  end

  it 'describes only the wired surfaces in the usage snippet' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      write_calendar(dir)
      Dir.mktmpdir do |cache|
        ext = Extension.new(profile_dir: dir, cache_dir: cache, surfaces: %i[mail])
        ext.configure(FakeConfigurator.new)
        snippet = ext.system_prompt_snippets.first
        assert_match(/local Thunderbird mail/, snippet)
        assert_match(/untrusted/, snippet)
        assert_match(/Search before you answer/, snippet, 'shared discipline still contributed')
        refute_match(/calendar/, snippet)
        refute_match(/contacts/, snippet)
      end
    end
  end

  it 'claims no inbound surface when only an outbound tool is wired' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      Dir.mktmpdir do |cache|
        ext = Extension.new(profile_dir: dir, cache_dir: cache, surfaces: [],
                            allow_compose_mail: true)
        ext.configure(FakeConfigurator.new)
        snippet = ext.system_prompt_snippets.first
        assert_match(/hand it off to Thunderbird/, snippet)
        refute_match(/Search before you answer/, snippet)
      end
    end
  end

  it 'wires contact search on Gloda presence, not the compose flag' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      Dir.mktmpdir do |cache|
        _, names = tool_names(dir, cache) # compose off
        assert_includes names, 'thunderbird_contact_search'
      end
    end
  end

  it 'omits contact search when Gloda is absent' do
    Dir.mktmpdir do |dir|
      write_calendar(dir) # no Gloda file
      Dir.mktmpdir do |cache|
        _, names = tool_names(dir, cache)
        refute_includes names, 'thunderbird_contact_search'
      end
    end
  end

  it 'does not wire compose by default (no-egress by construction)' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      Dir.mktmpdir do |cache|
        _, names = tool_names(dir, cache)
        refute_includes names, 'thunderbird_mail_compose'
      end
    end
  end

  it 'wires compose only when opted in' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      Dir.mktmpdir do |cache|
        c = FakeConfigurator.new
        Extension.new(profile_dir: dir, cache_dir: cache, allow_compose_mail: true).configure(c)
        assert_includes c.tools.map(&:name), 'thunderbird_mail_compose'
      end
    end
  end

  it 'does not wire calendar_create by default' do
    Dir.mktmpdir do |dir|
      write_calendar(dir)
      Dir.mktmpdir do |cache|
        _, names = tool_names(dir, cache)
        refute_includes names, 'thunderbird_calendar_create'
      end
    end
  end

  it 'wires calendar_create only when opted in (independently of compose)' do
    Dir.mktmpdir do |dir|
      write_calendar(dir) # no Gloda: create needs only a profile + binary
      Dir.mktmpdir do |cache|
        c = FakeConfigurator.new
        Extension.new(profile_dir: dir, cache_dir: cache, allow_create_calendar_event: true).configure(c)
        names = c.tools.map(&:name)
        assert_includes names, 'thunderbird_calendar_create'
        refute_includes names, 'thunderbird_mail_compose'
      end
    end
  end

  it 'wires compose even when Gloda is absent (novelty warn just degrades)' do
    Dir.mktmpdir do |dir|
      write_calendar(dir) # no Gloda file
      Dir.mktmpdir do |cache|
        c = FakeConfigurator.new
        Extension.new(profile_dir: dir, cache_dir: cache, allow_compose_mail: true).configure(c)
        names = c.tools.map(&:name)
        assert_includes names, 'thunderbird_mail_compose'
        refute_includes names, 'thunderbird_mail_search'
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

  it 'contributes the usage snippet (untrusted policy always, no draft stance inbound-only)' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      write_calendar(dir)
      Dir.mktmpdir do |cache|
        ext = Extension.new(profile_dir: dir, cache_dir: cache) # both allow_ off
        ext.configure(FakeConfigurator.new)
        snippet = ext.system_prompt_snippets.first
        assert_match(/<thunderbird_usage>/, snippet)
        assert_match(/untrusted/, snippet)
        refute_match(/hand it off to Thunderbird/, snippet) # no draft stance yet
      end
    end
  end

  it 'adds the draft-hand-off paragraph only when an outbound flag is wired' do
    Dir.mktmpdir do |dir|
      write_gloda(dir)
      Dir.mktmpdir do |cache|
        ext = Extension.new(profile_dir: dir, cache_dir: cache, allow_compose_mail: true)
        ext.configure(FakeConfigurator.new)
        assert_match(/hand it off to Thunderbird/, ext.system_prompt_snippets.first)
      end
    end
  end

  it 'contributes no snippet when Thunderbird is not installed' do
    skip 'a real Thunderbird root exists on this host' if Pikuri::Thunderbird::Profile.discover
    Dir.mktmpdir do |cache|
      ext = Extension.new(cache_dir: cache)
      ext.configure(FakeConfigurator.new)
      assert_empty ext.system_prompt_snippets
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
