# frozen_string_literal: true

require 'zlib'

module Pikuri
  module Demo
    # Tiny pictures for the demo: an RGB PNG of filled rectangles, written in
    # plain Ruby so the bytes are the same on every build.
    module Png
      # name => [width, height, background, [[x, y, w, h, colour], ...]]
      PICTURES = {
        'floor-plan' => [320, 200, [245, 245, 240],
                         [[10, 10, 300, 4, [40, 40, 40]], [10, 186, 300, 4, [40, 40, 40]],
                          [10, 10, 4, 180, [40, 40, 40]], [306, 10, 4, 180, [40, 40, 40]],
                          [200, 10, 4, 120, [40, 40, 40]], [210, 20, 90, 100, [180, 210, 240]],
                          *(0..5).map { |i| [24 + ((i % 3) * 56), 30 + ((i / 3) * 70), 40, 24, [200, 170, 120]] }]],
        'chata-1' => [160, 120, [120, 170, 220], [[0, 80, 160, 40, [70, 130, 60]], [50, 50, 60, 35, [140, 80, 50]]]],
        'chata-2' => [160, 120, [250, 200, 120], [[0, 90, 160, 30, [60, 90, 140]], [20, 20, 20, 20, [255, 240, 180]]]],
        'receipt' => [120, 200, [255, 255, 255], (0..7).map { |i| [10, 15 + (i * 22), 60 + ((i * 17) % 40), 6, [90, 90, 90]] }]
      }.freeze

      # @param name [String] a key of {PICTURES}.
      # @return [String] the PNG bytes.
      def self.named(name)
        width, height, background, rects = PICTURES.fetch(name)
        pixels = Array.new(height) { Array.new(width, background) }
        rects.each do |x, y, w, h, colour|
          (y...[y + h, height].min).each { |row| (x...[x + w, width].min).each { |col| pixels[row][col] = colour } }
        end
        raw = pixels.map { |row| "\0#{row.flatten.pack('C*')}" }.join
        header = [width, height, 8, 2, 0, 0, 0].pack('NNCCCCC')
        "\x89PNG\r\n\x1a\n".b + chunk('IHDR', header) + chunk('IDAT', Zlib::Deflate.deflate(raw)) + chunk('IEND', '')
      end

      # @return [String]
      def self.chunk(type, data)
        [data.bytesize].pack('N') + type.b + data.b + [Zlib.crc32(type + data)].pack('N')
      end
      private_class_method :chunk
    end
  end
end
