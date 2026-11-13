# frozen_string_literal: true

namespace :demo do
  desc 'Build the demo Thunderbird profile (bin/pikuri-demo-mailbox; DIR=... builds beside a real one)'
  task :build do
    args = ENV['DIR'] ? ['--dir', ENV['DIR']] : []
    ruby File.expand_path('../bin/pikuri-demo-mailbox', __dir__), *args
  end
end
