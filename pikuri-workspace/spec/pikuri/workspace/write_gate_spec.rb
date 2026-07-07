# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::WriteGate do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-wg-')).realpath }
  after { FileUtils.rm_rf(root) }

  def approving
    c = Object.new
    c.define_singleton_method(:decide) do |request:|
      Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
    end
    c
  end

  def rejecting(reason)
    c = Object.new
    c.define_singleton_method(:decide) do |request:|
      Pikuri::Workspace::Confirmer::Rejected.new(reason: reason)
    end
    c
  end

  def never_called
    c = Object.new
    c.define_singleton_method(:decide) { |request:| raise "confirmer must not be consulted (#{request.inspect})" }
    c
  end

  describe '.writable_target?' do
    it 'is true for an existing writable file' do
      f = root + 'a.txt'
      File.write(f, 'x')
      assert_equal true, described_class.writable_target?(f)
    end

    it 'is true for a new file under a writable dir (walks to the nearest ancestor)' do
      assert_equal true, described_class.writable_target?(root + 'nested/deep/new.txt')
    end

    it 'is false for a target under an unwritable dir' do
      next if Process.uid.zero? # root bypasses permission bits

      locked = root + 'locked'
      FileUtils.mkdir_p(locked)
      File.chmod(0o555, locked)
      assert_equal false, described_class.writable_target?(locked + 'x.txt')
    ensure
      File.chmod(0o755, locked) if locked&.exist?
    end
  end

  describe '.check' do
    let(:change) { Pikuri::Workspace::Confirmer::Change.new(path: 'a.txt', old: 'x', new: 'y') }

    def existing_target
      f = root + 'a.txt'
      File.write(f, 'x')
      f
    end

    it 'returns nil (proceed) when writable and approved' do
      assert_nil described_class.check(confirmer: approving, path: 'a.txt',
                                       resolved: existing_target, question: 'OK?', change: change)
    end

    it 'returns a declined observation carrying the reason' do
      result = described_class.check(confirmer: rejecting('use vim'), path: 'a.txt',
                                     resolved: existing_target, question: 'OK?', change: change)
      assert_includes result, 'user declined the write to a.txt: use vim'
    end

    it 'declines without a reason cleanly' do
      result = described_class.check(confirmer: rejecting(nil), path: 'a.txt',
                                     resolved: existing_target, question: 'OK?', change: change)
      assert_equal 'Error: user declined the write to a.txt.', result
    end

    it 'short-circuits to permission-denied without consulting the confirmer' do
      next if Process.uid.zero?

      locked = root + 'locked'
      FileUtils.mkdir_p(locked)
      File.chmod(0o555, locked)
      result = described_class.check(confirmer: never_called, path: 'locked/x.txt',
                                     resolved: locked + 'x.txt', question: 'OK?', change: change)
      assert_includes result, 'permission denied'
    ensure
      File.chmod(0o755, locked) if locked&.exist?
    end
  end
end
