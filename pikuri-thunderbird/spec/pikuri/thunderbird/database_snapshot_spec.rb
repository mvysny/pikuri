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

  it 'reads a plausible change counter from a real DB header' do
    Dir.mktmpdir do |dir|
      counter = DatabaseSnapshot.change_counter(make_db(dir))
      assert_kind_of Integer, counter
      assert counter >= 0
    end
  end

  it 'returns nil change_counter for a missing/short file' do
    Dir.mktmpdir do |dir|
      assert_nil DatabaseSnapshot.change_counter(File.join(dir, 'nope.sqlite'))
      short = File.join(dir, 'short')
      File.write(short, 'x')
      assert_nil DatabaseSnapshot.change_counter(short)
    end
  end

  it 'takes a settled copy and stamps its generation' do
    Dir.mktmpdir do |dir|
      src = make_db(dir)
      snap = DatabaseSnapshot.new(source: src, dir: File.join(dir, 'cache'))
      assert snap.refresh, 'first refresh takes a copy'
      assert File.file?(snap.path), 'copy exists'
      assert_equal DatabaseSnapshot.change_counter(src), snap.generation
      # the copy is a usable DB
      copy = SQLite3::Database.new("file:#{snap.path}?immutable=1", flags: SQLite3::Constants::Open::READONLY)
      assert_equal [[1]], copy.execute('SELECT x FROM t')
      copy.close
    end
  end

  it 'refresh is a no-op until the source generation moves' do
    Dir.mktmpdir do |dir|
      src = make_db(dir)
      snap = DatabaseSnapshot.new(source: src, dir: File.join(dir, 'cache'))
      snap.refresh
      gen1 = snap.generation
      refute snap.refresh, 'unchanged source → no re-copy'

      bump(src)
      assert snap.refresh, 'changed source → re-copy'
      refute_equal gen1, snap.generation
    end
  end

  it 'raises TornError when the source cannot be copied' do
    Dir.mktmpdir do |dir|
      snap = DatabaseSnapshot.new(source: File.join(dir, 'ghost.sqlite'), dir: File.join(dir, 'cache'))
      assert_raises(DatabaseSnapshot::TornError) { snap.refresh(attempts: 2, backoff: 0) }
    end
  end
end
