# frozen_string_literal: true

require 'date'
require 'erb'
require 'yaml'

module Pikuri
  module Demo
    # +dev/thunderbird-testbed/facts.yml+, read for one build day. The templates (+mail.yml+,
    # +documents/+) are ERB with this object as +f+:
    #
    #   <%= f.invoice.iban %>              # nested keys read as methods
    #   <%= f.day(f.invoice.due) %>        # "18 November 2026"
    #   <%= f.person(:mira) %>             # "Mira Koskinen <mira@lumo-studio.example>"
    class Facts
      # Read-only dot access over a YAML hash.
      class Node
        # @param hash [Hash]
        def initialize(hash)
          @hash = hash
        end

        # @return [Object, nil] the value under +key+ (a {Node} for a hash).
        def [](key) = wrap(@hash[key.to_s])

        # @return [Hash] the underlying hash.
        def to_h = @hash

        def method_missing(name, *args)
          return super unless args.empty? && @hash.key?(name.to_s)

          wrap(@hash[name.to_s])
        end

        def respond_to_missing?(name, include_private = false) = @hash.key?(name.to_s) || super

        private

        def wrap(value)
          case value
          when Hash then Node.new(value)
          when Array then value.map { |v| v.is_a?(Hash) ? Node.new(v) : v }
          else value
          end
        end
      end

      # The facts file.
      PATH = File.expand_path('../facts.yml', __dir__)

      # @return [Date] the day the build is relative to.
      attr_reader :today

      # @param today [Date]
      def initialize(today:)
        @today = today
        @root = Node.new(YAML.safe_load_file(PATH))
      end

      # @param offset [Integer] days from {#today}.
      # @return [Date]
      def date(offset) = @today + offset

      # @param offset [Integer]
      # @return [String] e.g. "18 November 2026".
      def day(offset) = date(offset).strftime('%-d %B %Y')

      # @param offset [Integer]
      # @return [String] e.g. "2026-11-18".
      def iso(offset) = date(offset).iso8601

      # @param weekday [String] e.g. "thursday".
      # @return [Integer] days from {#today} to the next such weekday (0 if today).
      def next_weekday(weekday)
        (Date::DAYNAMES.map(&:downcase).index(weekday.to_s) - @today.wday) % 7
      end

      # @param key [Symbol, String] a key under +people+, or +:owner+.
      # @return [String] "Name <address>".
      def person(key)
        p = key.to_s == 'owner' ? @root.owner : @root.people[key]
        raise ArgumentError, "no person #{key.inspect} in #{PATH}" unless p

        "#{p.name} <#{p.email}>"
      end

      # @param key [Symbol, String]
      # @return [String] the bare address.
      def email(key) = person(key)[/<(.+)>/, 1]

      # @param amount [Numeric]
      # @return [String] e.g. "EUR 1,284.50".
      def eur(amount)
        whole, cents = format('%.2f', amount).split('.')
        "EUR #{whole.reverse.scan(/\d{1,3}/).join(',').reverse}.#{cents}"
      end

      # Renders an ERB template with this object as +f+.
      #
      # @param text [String]
      # @return [String]
      def render(text)
        f = self
        ERB.new(text, trim_mode: '-').result(binding)
      end

      def method_missing(name, *args)
        return super unless args.empty? && @root.respond_to?(name)

        @root.public_send(name)
      end

      def respond_to_missing?(name, include_private = false) = @root.respond_to?(name) || super
    end
  end
end
