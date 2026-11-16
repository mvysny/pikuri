# frozen_string_literal: true

require 'tmpdir'
require 'sqlite3'

describe Pikuri::Thunderbird::DatabaseSnapshot do
  DatabaseSnapshot = Pikuri::Thunderbird::DatabaseSnapshot

  # Create a real SQLite DB (valid header + change counter) and return its path.
  def make_db(dir, name = 'src.sqlite')
    path = File.join(dir, name)
    db = SQLite3::Database.new(path)
    db.execute('CREATE TABLE t(x)')
    db.execute('INSERT INTO t VALUES (1)')
    db.close
    path
  end

  # A write bumps SQLite's change counter.
  def bump(path)
    db = SQLite3::Database.new(path)
    db.execute('INSERT INTO t VALUES (2)')
    db.close
  end

  # A WAL store held open the way Thunderbird holds one: row 1 checkpointed
  # into the main file, row 2 committed but still only in +-wal+. The
  # connection stays open, since closing it would checkpoint.
  def open_wal_db(dir)
    db = SQLite3::Database.new(File.join(dir, 'cache.sqlite'))
    db.execute('PRAGMA locking_mode=EXCLUSIVE')
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA wal_autocheckpoint=0')
    db.execute('CREATE TABLE t(x)')
    db.execute('INSERT INTO t VALUES (1)')
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    db.execute('INSERT INTO t VALUES (2)')
    db
  end

  # The rows of +t+ as a normal read-only open of the copy sees them.
  def rows(snap)
    copy = SQLite3::Database.new(snap.path, flags: SQLite3::Constants::Open::READONLY)
    copy.execute('SELECT x FROM t ORDER BY x').flatten
  ensure
    copy&.close
  end

  it 'reads the change counter, with no WAL parts for a rollback-journal DB' do
    Dir.mktmpdir do |dir|
      counter, salt, size = DatabaseSnapshot.generation(make_db(dir))
      assert_kind_of Integer, counter
      assert_nil salt
      assert_nil size
    end
  end

  it 'returns a nil generation for a missing/short file' do
    Dir.mktmpdir do |dir|
      assert_nil DatabaseSnapshot.generation(File.join(dir, 'nope.sqlite'))
      short = File.join(dir, 'short')
      File.write(short, 'x')
      assert_nil DatabaseSnapshot.generation(short)
    end
  end

  it 'takes a usable copy' do
    Dir.mktmpdir do |dir|
      snap = DatabaseSnapshot.new(source: make_db(dir), dir: File.join(dir, 'cache'))
      refute snap.current?, 'no copy yet'
      assert snap.refresh, 'first refresh takes a copy'
      assert snap.current?
      assert_equal [1], rows(snap)
    end
  end

  it 'refresh is a no-op until the source generation moves' do
    Dir.mktmpdir do |dir|
      src = make_db(dir)
      snap = DatabaseSnapshot.new(source: src, dir: File.join(dir, 'cache'))
      snap.refresh
      refute snap.refresh, 'unchanged source → no re-copy'

      bump(src)
      refute snap.current?
      assert snap.refresh, 'changed source → re-copy'
      assert_equal [1, 2], rows(snap)
    end
  end

  it 'sees a commit that sits only in the WAL' do
    Dir.mktmpdir do |dir|
      live = open_wal_db(dir)
      snap = DatabaseSnapshot.new(source: File.join(dir, 'cache.sqlite'), dir: File.join(dir, 'cache'))
      snap.refresh
      assert_equal [1, 2], rows(snap)
    ensure
      live&.close
    end
  end

  it 'goes stale on a WAL-only commit' do
    Dir.mktmpdir do |dir|
      live = open_wal_db(dir)
      src = File.join(dir, 'cache.sqlite')
      snap = DatabaseSnapshot.new(source: src, dir: File.join(dir, 'cache'))
      snap.refresh
      counter = DatabaseSnapshot.generation(src).first

      live.execute('INSERT INTO t VALUES (3)')
      assert_equal counter, DatabaseSnapshot.generation(src).first, 'the header counter alone misses it'
      refute snap.current?
      assert snap.refresh
      assert_equal [1, 2, 3], rows(snap)
    ensure
      live&.close
    end
  end

  it 'drops its old WAL copy once the source has checkpointed' do
    Dir.mktmpdir do |dir|
      live = open_wal_db(dir)
      src = File.join(dir, 'cache.sqlite')
      snap = DatabaseSnapshot.new(source: src, dir: File.join(dir, 'cache'))
      snap.refresh
      rows(snap) # a read-only open leaves the copy's -wal and -shm behind

      live.execute('PRAGMA wal_checkpoint(TRUNCATE)')
      live.close
      live = nil
      refute File.exist?("#{src}-wal"), 'closing the source checkpointed and removed its WAL'
      assert snap.refresh
      refute File.exist?("#{snap.path}-wal")
      assert_equal [1, 2], rows(snap)
    ensure
      live&.close
    end
  end

  it 'raises TornError when the source cannot be copied' do
    Dir.mktmpdir do |dir|
      snap = DatabaseSnapshot.new(source: File.join(dir, 'ghost.sqlite'), dir: File.join(dir, 'cache'))
      assert_raises(DatabaseSnapshot::TornError) { snap.refresh(attempts: 2, backoff: 0) }
    end
  end

  # A +-journal+ beside the source is a write in flight; while it stays, no
  # try settles.
  it 'raises the busy text when Thunderbird keeps writing and there is no copy yet' do
    Dir.mktmpdir do |dir|
      src = make_db(dir)
      File.write("#{src}-journal", '')
      snap = DatabaseSnapshot.new(source: src, dir: File.join(dir, 'cache'))
      error = assert_raises(DatabaseSnapshot::TornError) { snap.refresh(attempts: 2, backoff: 0) }
      assert_equal DatabaseSnapshot::BUSY, error.message
    end
  end

  it 'keeps serving the older copy while Thunderbird keeps writing' do
    Dir.mktmpdir do |dir|
      src = make_db(dir)
      snap = DatabaseSnapshot.new(source: src, dir: File.join(dir, 'cache'))
      snap.refresh
      older = snap.path

      bump(src)
      File.write("#{src}-journal", '')
      refute snap.refresh(attempts: 2, backoff: 0), 'busy → no fresh copy'
      assert_equal older, snap.path
      assert_equal [1], rows(snap), 'the failed tries left the older copy intact'
      refute snap.current?, 'still stale, so the next query tries again'

      File.delete("#{src}-journal")
      assert snap.refresh
      refute_equal older, snap.path, 'the fresh copy lands in the other slot'
      assert_equal [1, 2], rows(snap)
    end
  end

  it 'leaves an open connection to the older copy readable across a refresh' do
    Dir.mktmpdir do |dir|
      src = make_db(dir)
      snap = DatabaseSnapshot.new(source: src, dir: File.join(dir, 'cache'))
      snap.refresh
      older = SQLite3::Database.new(snap.path, flags: SQLite3::Constants::Open::READONLY)

      bump(src)
      assert snap.refresh
      assert_equal [1], older.execute('SELECT x FROM t ORDER BY x').flatten
      assert_equal [1, 2], rows(snap)
    ensure
      older&.close
    end
  end
end
