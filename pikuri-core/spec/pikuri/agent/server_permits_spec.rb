# frozen_string_literal: true

# The registry is process-global, so every example resets it — one example's
# server must not ration another's.
RSpec.describe Pikuri::Agent::ServerPermits do
  after { described_class.reset! }

  let(:semaphore_class) { Pikuri::Agent::ServerPermits::Semaphore }
  let(:cancelled) { Pikuri::Agent::Control::Cancellable::Cancelled }

  describe '.key_for' do
    it 'normalizes a trailing slash and /v1 to one key, as ChatTransport does' do
      keys = ['http://x:8080', 'http://x:8080/', 'http://x:8080/v1', 'http://x:8080/v1/']
                .map { |s| described_class.key_for(s) }

      assert_equal ['http://x:8080'], keys.uniq
    end

    it 'is nil when there is no server to key on' do
      [nil, '', '   ', '/'].each { |blank| assert_nil described_class.key_for(blank) }
    end
  end

  describe '.limit / .for' do
    it 'sizes a server, keyed past the /v1 difference' do
      described_class.limit('http://x:8080/v1', 2)

      assert_equal 2, described_class.for('http://x:8080').permits
      assert_equal({ 'http://x:8080' => 2 }, described_class.sizes)
    end

    it 'hands out the same semaphore for one server, so agents share the queue' do
      described_class.limit('http://x:8080', 1)

      assert_same described_class.for('http://x:8080'), described_class.for('http://x:8080/v1/')
    end

    it 'answers UNLIMITED for an unsized server and for no server at all' do
      assert_same described_class::UNLIMITED, described_class.for('http://unsized:8080')
      assert_same described_class::UNLIMITED, described_class.for(nil)
    end

    it 'takes nil as an explicit "this server does not care"' do
      described_class.limit('https://api.openai.com/v1', nil)

      assert_same described_class::UNLIMITED, described_class.for('https://api.openai.com')
      assert_equal({ 'https://api.openai.com' => nil }, described_class.sizes)
    end

    it 'rebuilds the semaphore when the size changes, so a re-limit takes effect' do
      described_class.limit('http://x:8080', 1)
      first = described_class.for('http://x:8080')
      described_class.limit('http://x:8080', 3)

      refute_same first, described_class.for('http://x:8080')
      assert_equal 3, described_class.for('http://x:8080').permits
    end

    it 'keeps the semaphore when a re-limit repeats the current size' do
      described_class.limit('http://x:8080', 2)
      first = described_class.for('http://x:8080')
      described_class.limit('http://x:8080', 2)

      assert_same first, described_class.for('http://x:8080')
    end

    it 'refuses a non-positive or non-Integer size, and a blank server' do
      assert_raises(ArgumentError) { described_class.limit('http://x:8080', 0) }
      assert_raises(ArgumentError) { described_class.limit('http://x:8080', -1) }
      assert_raises(ArgumentError) { described_class.limit('http://x:8080', '2') }
      assert_raises(ArgumentError) { described_class.limit('http://x:8080', 1.5) }
      assert_raises(ArgumentError) { described_class.limit('', 1) }
    end
  end

  describe '.default' do
    it 'sizes an unsized server' do
      described_class.default('http://x:8080', 4)

      assert_equal 4, described_class.for('http://x:8080').permits
    end

    it 'never overrides a host-set limit, whichever lands first' do
      described_class.limit('http://x:8080', 1)
      described_class.default('http://x:8080', 4)
      assert_equal 1, described_class.for('http://x:8080').permits

      described_class.reset!
      described_class.default('http://y:8080', 4)
      described_class.limit('http://y:8080', 1)
      assert_equal 1, described_class.for('http://y:8080').permits
    end

    it 'lets the first probe win over a later one' do
      described_class.default('http://x:8080', 4)
      described_class.default('http://x:8080', 1)

      assert_equal 4, described_class.for('http://x:8080').permits
    end
  end

  describe '.reset!' do
    it 'forgets every size and permit object' do
      described_class.limit('http://x:8080', 1)
      described_class.reset!

      assert_equal({}, described_class.sizes)
      assert_same described_class::UNLIMITED, described_class.for('http://x:8080')
    end
  end

  # A String, not the class: a nested +describe <Class>+ would rebind
  # +described_class+ and take the registry-resetting +after+ hook with it.
  describe 'Semaphore' do
    # Wait for +condition+ rather than sleeping a guessed interval: the whole
    # point is a handoff between threads, and a fixed sleep is either flaky or
    # slow. Fails loudly instead of hanging the suite.
    def wait_until(timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert yield, 'condition never became true'
    end

    it 'never lets more than `permits` blocks run at once' do
      sem = semaphore_class.new(2)
      lock = Mutex.new
      in_flight = 0
      peak = 0
      ran = 0

      6.times.map do
        Thread.new do
          sem.acquire do
            lock.synchronize { in_flight += 1; peak = [peak, in_flight].max }
            sleep 0.02
            lock.synchronize { in_flight -= 1; ran += 1 }
          end
        end
      end.each(&:join)

      assert_equal 6, ran
      assert_equal 2, peak
    end

    it 'returns the block value and releases the permit' do
      sem = semaphore_class.new(1)

      assert_equal :done, sem.acquire { :done }
      assert_equal 1, sem.available
    end

    it 'releases the permit when the block raises' do
      sem = semaphore_class.new(1)

      assert_raises(RuntimeError) { sem.acquire { raise 'boom' } }
      assert_equal 1, sem.available
    end

    it 'is a bare yield when unlimited — no lock, no bookkeeping' do
      sem = semaphore_class.new(nil)
      peak = 0
      lock = Mutex.new
      in_flight = 0

      4.times.map do
        Thread.new do
          sem.acquire do
            lock.synchronize { in_flight += 1; peak = [peak, in_flight].max }
            sleep 0.02
            lock.synchronize { in_flight -= 1 }
          end
        end
      end.each(&:join)

      assert_equal 4, peak
      assert_nil sem.available
      assert_equal 'unlimited', sem.to_s
    end

    it 'raises Cancelled while parked, without waiting for the permit to free' do
      sem = semaphore_class.new(1)
      cancellable = Pikuri::Agent::Control::Cancellable.new
      hold = Queue.new
      holder = Thread.new { sem.acquire { hold.pop } }
      wait_until { sem.available.zero? }

      waiter = Thread.new do
        sem.acquire(cancellable: cancellable) { :ran }
      rescue cancelled
        :cancelled
      end
      cancellable.cancel!

      # The holder is still holding: the wait was cut short, not satisfied.
      assert_equal :cancelled, waiter.value
      assert_equal 0, sem.available

      hold << :go
      holder.join
      assert_equal 1, sem.available
    end

    it 'raises before taking a permit when already cancelled' do
      sem = semaphore_class.new(1)
      cancellable = Pikuri::Agent::Control::Cancellable.new
      cancellable.cancel!

      assert_raises(cancelled) { sem.acquire(cancellable: cancellable) { flunk 'ran anyway' } }
      assert_equal 1, sem.available
    end

    it 'reports its state for a debug print' do
      sem = semaphore_class.new(2)

      assert_equal '2/2 permits', sem.to_s
      sem.acquire { assert_equal '1/2 permits', sem.to_s }
    end
  end
end
