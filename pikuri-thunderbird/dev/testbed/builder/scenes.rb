# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'
require 'yaml'

module Pikuri
  module Demo
    # The hand-written scene messages of +pikuri-thunderbird/dev/testbed/mail.yml+, each there to
    # make a scene of the secretary chapter happen. The file's header lists
    # the keys; this turns them into +mail+ gem messages.
    class Scenes
      # The scene file.
      PATH = File.expand_path('../mail.yml', __dir__)

      # Attachment sources: +<name>.<format>.html+, converted.
      ATTACHMENTS = File.expand_path('../mail', __dir__)

      # @param facts [Facts]
      # @param calendar [Calendar]
      # @param documents [Documents]
      # @param converter [Converter]
      def initialize(facts:, calendar:, documents:, converter:)
        @facts = facts
        @calendar = calendar
        @documents = documents
        @converter = converter
      end

      # @return [Hash{String => Array<Mail::Message>}] folder to messages.
      def folders
        @folders ||= begin
          scenes = YAML.safe_load(@facts.render(File.read(PATH)))
          ids = scenes.to_h { |s| [s['id'], "#{s['id']}@#{domain(s['from'])}"] }
          built = {}
          # Forwards last, so the message they carry is built.
          scenes.sort_by { |s| s['forward'] ? 1 : 0 }.each { |s| built[s['id']] = message(s, ids, built) }
          scenes.reject { |s| s['folder'] == 'none' }
                .group_by { |s| s['folder'] || 'Inbox' }
                .transform_values { |list| list.map { |s| built.fetch(s['id']) } }
        end
      end

      private

      # @return [Mail::Message]
      def message(scene, ids, built)
        message = Mail.new
        message.from = @facts.person(scene['from'])
        message.to = Array(scene['to'] || 'owner').map { |k| @facts.person(k) }
        message.cc = scene['cc'].map { |k| @facts.person(k) } if scene['cc']
        days, hhmm = scene['at']
        message.date = Demo.local_time(@facts.date(days), hhmm)
        message.message_id = "<#{ids.fetch(scene['id'])}>"
        message.subject = scene['subject']
        if (thread = scene['reply_to'])
          refs = thread.map { |id| "<#{ids.fetch(id)}>" }
          message.in_reply_to = refs.last
          message.references = refs.join(' ')
        end
        extras = attachments(scene) + Array(scene['forward'] && Mime.forwarded(built.fetch(scene['forward'])))
        body = body_part(scene)
        top = extras.empty? ? body : Mime.multipart('mixed', [body, *extras])
        Mime.finish(message, top, scene['id'])
      end

      # @return [Mail::Part] text, HTML (with its images) and an invitation,
      #   as alternatives of one another.
      def body_part(scene)
        alternatives = []
        alternatives << Mime.text(scene['body']) if scene['body']
        if scene['html']
          html = Mime.text(scene['html'], 'html')
          if scene['related']
            images = scene['related'].map { |r| Mime.inline_image(r['name'], Png.named(r['png']), r['cid']) }
            html = Mime.multipart('related', [html, *images])
          end
          alternatives << html
        end
        alternatives << Mime.calendar(@calendar.invite(scene['invite']), method: 'REQUEST') if scene['invite']
        alternatives.size == 1 ? alternatives.first : Mime.multipart('alternative', alternatives)
      end

      # @return [Array<Mail::Part>]
      def attachments(scene)
        parts = Array(scene['attachments']).map { |a| attachment(a) }
        parts << Mime.attachment("#{scene['ics']}.ics", @calendar.ics_file(scene['ics']), type: 'text/calendar') if scene['ics']
        parts
      end

      # @param spec [Hash] one +attachments+ entry.
      # @return [Mail::Part]
      def attachment(spec)
        part = attachment_part(spec)
        spec['rfc2231'] ? Mime.rfc2231(part, spec['name']) : part
      end

      # @param spec [Hash]
      # @return [Mail::Part]
      def attachment_part(spec)
        if spec['document']
          bytes = @documents.files.fetch(spec['document'])
          Mime.attachment(spec['name'] || File.basename(spec['document']), bytes)
        elsif spec['source']
          base, to = spec['source'].split(/\.(?=[a-z]+\z)/)
          html = @facts.render(File.read(File.join(ATTACHMENTS, "#{spec['source']}.html")))
          Mime.attachment(spec['name'] || "#{base}.#{to}", @converter.convert(html, to))
        elsif spec['text']
          Mime.attachment(spec['name'], spec['text'], type: spec['type'])
        elsif spec['png']
          Mime.attachment(spec['name'], Png.named(spec['png']), type: 'image/png')
        elsif spec['zip']
          Mime.attachment(spec['name'], zip(spec['zip']), type: 'application/zip')
        elsif spec['bytes']
          Mime.attachment(spec['name'], filler(spec['bytes']), type: spec['type'])
        else
          raise "attachment without a source in #{PATH}: #{spec.inspect}"
        end
      end

      # A zip of {Png} pictures, byte-stable: fixed times, no extra fields.
      #
      # @param names [Array<String>] e.g. "chata-1.png".
      # @return [String]
      def zip(names)
        Dir.mktmpdir('pikuri-demo-zip-') do |tmp|
          names.each do |name|
            path = File.join(tmp, name)
            File.binwrite(path, Png.named(File.basename(name, '.png')))
            File.utime(Time.utc(2026, 1, 1), Time.utc(2026, 1, 1), path)
          end
          _out, err, status = Open3.capture3('zip', '-q', '-X', '-D', 'out.zip', *names, chdir: tmp)
          raise "zip failed: #{err}" unless status.success?

          File.binread(File.join(tmp, 'out.zip'))
        end
      end

      # Filler for the oversized attachment, the same on every build.
      #
      # @param size [Integer]
      # @return [String]
      def filler(size)
        block = Random.new(42).bytes(64 * 1024)
        (block * ((size / block.bytesize) + 1)).byteslice(0, size)
      end

      # @param key [String] a people key or "owner".
      # @return [String]
      def domain(key) = @facts.email(key).split('@').last
    end
  end
end
