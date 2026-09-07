# frozen_string_literal: true

require 'tmpdir'

describe Pikuri::Thunderbird::CalendarCreate do
  around do |ex|
    old = ENV['TZ']
    ENV['TZ'] = 'UTC'
    ex.run
    ENV['TZ'] = old
  end

  # A tool whose launcher records the path instead of spawning Thunderbird.
  def tool(dir, raising: false)
    @opened = []
    opened = @opened
    launcher = Object.new
    launcher.define_singleton_method(:launch) do |arg|
      raise Pikuri::Thunderbird::Launcher::Error, 'thunderbird not found' if raising

      opened << arg
    end
    # Profile#outbox_dir already includes the pikuri-outbox leaf; mirror that.
    profile = Struct.new(:outbox_dir).new(File.join(dir, 'pikuri-outbox'))
    Pikuri::Thunderbird::CalendarCreate.new(profile: profile, launcher: launcher)
  end

  it 'stages an .ics under the outbox and hands off its path' do
    Dir.mktmpdir do |dir|
      out = tool(dir).run('title' => 'Dentist', 'start' => '2026-07-20 14:00').to_s
      assert_equal 1, @opened.size
      path = @opened.first
      assert_equal File.join(dir, 'pikuri-outbox'), File.dirname(path)
      assert_match(/\.ics\z/, path)
      assert_match(/Nothing has been added yet/, out)

      body = File.read(path)
      assert_match(/^SUMMARY:Dentist\r$/, body)
      assert_match(/^DTSTART:20260720T140000Z\r$/, body)
    end
  end

  it 'builds an all-day event from a bare date' do
    Dir.mktmpdir do |dir|
      tool(dir).run('title' => 'Holiday', 'start' => '2026-07-20', 'all_day' => true)
      body = File.read(@opened.first)
      assert_match(/^DTSTART;VALUE=DATE:20260720\r$/, body)
    end
  end

  it 'passes location and description through' do
    Dir.mktmpdir do |dir|
      tool(dir).run('title' => 'x', 'start' => '2026-07-20 09:00',
                    'location' => 'Room 3', 'description' => 'bring figures')
      body = File.read(@opened.first)
      assert_match(/^LOCATION:Room 3\r$/, body)
      assert_match(/^DESCRIPTION:bring figures\r$/, body)
    end
  end

  it 'Errors on an unparseable date and stages nothing' do
    Dir.mktmpdir do |dir|
      out = tool(dir).run('title' => 'x', 'start' => 'not-a-date').to_s
      assert_empty @opened
      assert_match(/\AError: bad date/, out)
    end
  end

  it 'turns a hand-off failure into an Error observation' do
    Dir.mktmpdir do |dir|
      out = tool(dir, raising: true).run('title' => 'x', 'start' => '2026-07-20 14:00').to_s
      assert_match(/\AError: thunderbird not found/, out)
    end
  end
end
