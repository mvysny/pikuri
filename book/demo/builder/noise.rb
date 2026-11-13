# frozen_string_literal: true

require 'mail'

module Pikuri
  module Demo
    # The everyday mail around the scenes — newsletters, CI builds, parcels,
    # a mailing list, bank statements, receipts — so a search has something to
    # rank past. Seeded templates: the same messages on every build.
    class Noise
      # The noise's own senders. RFC 2606 domains, like the facts'.
      CI = 'Novak CI <ci@builds.novak.example>'
      PARCEL = 'Parcel Tracker <noreply@parcel-tracker.example>'
      SAUNA_DIGEST = 'Sauna Builders Digest <digest@sauna-digest.example>'
      LUMO_WEEKLY = 'Lumo Weekly <news@lumo-studio.example>'
      CAFE = 'Kahvila Kuu <receipts@kahvila-kuu.example>'
      LIST = 'riders@helsinki-cycling.example'
      RIDERS = ['Juha Salo <juha.salo@inbox.example>', 'Katja Nieminen <katja@kotiposti.example>',
                'Olli Rantanen <olli.r@inbox.example>', 'Hanna Lind <hanna.lind@posti-mail.example>'].freeze

      # @param facts [Facts]
      def initialize(facts:)
        @facts = facts
        @random = Random.new(2026)
      end

      # @return [Hash{String => Array<Mail::Message>}] folder to messages.
      def folders
        @folders ||= begin
          inbox = ci + parcels + newsletters + statements + receipts
          list_inbox, list_sent = cycling_list
          { 'Inbox' => inbox + list_inbox, 'Sent' => list_sent }
        end
      end

      private

      # @return [Array<Mail::Message>]
      def ci
        (1..60).map do |n|
          build = 1200 + n
          failed = (n % 7).zero?
          branch = %w[main main main shop-redesign copy-update].fetch(n % 5)
          plain(CI, "ci-#{build}", day: -120 + (n * 2), subject: "[novak/site] Build ##{build} #{failed ? 'failed' : 'passed'} (#{branch})",
                                   body: "Build ##{build} on #{branch} #{failed ? 'failed at the test step: 1 of 214 specs failed' : 'passed: 214 specs, 0 failures'}.\n" \
                                         "Duration: #{60 + @random.rand(240)} s.\n")
        end
      end

      # @return [Array<Mail::Message>]
      def parcels
        items = ['sauna stones (25 kg)', 'a bicycle chain', 'two books', 'a kettle descaler', 'cardamom (500 g)',
                 'ink cartridges', 'a heat shield', 'winter tyres', 'a USB-C hub', 'wool socks']
        (1..20).map do |n|
          code = format('JJFI%<n>010d', n: 6_402_118_000 + (n * 37))
          step = ['is on its way', 'has arrived at the pickup point', 'was delivered'].fetch(n % 3)
          plain(PARCEL, "parcel-#{n}", day: -110 + (n * 5),
                                       subject: "Your parcel #{code} #{step}",
                                       body: "Your parcel #{code} (#{items.fetch(n % items.size)}) #{step}.\n" \
                                             "Pickup point: K-Market Kamppi, open 7-23.\n")
        end
      end

      # @return [Array<Mail::Message>] HTML-only and multipart/alternative.
      def newsletters
        topics = ['colour and light', 'type on small screens', 'the case for slow sites', 'shop checkouts that work',
                  'photographing interiors', 'accessibility audits', 'writing microcopy', 'dark mode, honestly',
                  'image formats in practice', 'forms people finish', 'print stylesheets', 'the humble footer']
        lumo = topics.each_with_index.map do |topic, i|
          html = "<h1>Lumo Weekly</h1><p>This week: <b>#{topic}</b>.</p>" \
                 "<p>Three links, one opinion, and a photo from the studio.</p><p><a href=\"https://lumo-studio.example/weekly/#{i + 30}\">Read online</a></p>"
          message(LUMO_WEEKLY, "weekly-#{i + 30}", day: -84 + (i * 7), subject: "Lumo Weekly: #{topic}",
                                                   top: Mime.text(html, 'html'))
        end
        stoves = ['Choosing stones', 'Ventilation myths', 'Heat shields compared', 'Löyly and humidity',
                  'Wood: birch or alder?', 'Chimney sweeps and you', 'Benches that last', 'Electric vs wood',
                  'Doors and glass', 'The first firing', 'Winter maintenance', 'Lighting the sauna']
        digest = stoves.each_with_index.map do |title, i|
          text = "Sauna Builders Digest ##{i + 101}\n\n#{title}\n\nThis issue answers readers' questions about #{title.downcase}.\n"
          html = "<h2>Sauna Builders Digest ##{i + 101}</h2><h3>#{title}</h3><p>This issue answers readers' questions about #{title.downcase}.</p>"
          message(SAUNA_DIGEST, "digest-#{i + 101}", day: -88 + (i * 7), subject: "Sauna Builders Digest ##{i + 101}: #{title}",
                                                     top: Mime.multipart('alternative', [Mime.text(text), Mime.text(html, 'html')]))
        end
        lumo + digest
      end

      # @return [Array<Mail::Message>] monthly, from the real bank domain.
      def statements
        (1..4).map do |n|
          month = (@facts.today << n).strftime('%B %Y')
          html = "<p>Dear Alex Novak,</p><p>your account statement for <b>#{month}</b> is ready in online banking.</p>" \
                 '<p>Northwind Bank</p>'
          text = "Dear Alex Novak,\n\nyour account statement for #{month} is ready in online banking.\n\nNorthwind Bank\n"
          message(@facts.person(:bank), "statement-#{n}", day: -(n * 30) + 3,
                                                          subject: "Your statement for #{month} is ready",
                                                          top: Mime.multipart('alternative', [Mime.text(text), Mime.text(html, 'html')]))
        end
      end

      # @return [Array<Mail::Message>]
      def receipts
        orders = ['oat latte and a cardamom bun', 'two espressos', 'filter coffee and a sandwich', 'a pot of tea',
                  'lunch soup', 'a cinnamon bun', 'cappuccino', 'two lattes and a bun', 'iced coffee', 'a slice of cake']
        orders.each_with_index.map do |order, i|
          price = format('%.2f', 3.2 + ((i * 1.7) % 9))
          plain(CAFE, "receipt-#{i + 1}", day: -60 + (i * 6), subject: "Your receipt from Kahvila Kuu",
                                          body: "Thank you!\n\n#{order}: EUR #{price}\nPaid by card.\n")
        end
      end

      # A mailing list with threads and a few of Alex's replies.
      #
      # @return [Array(Array<Mail::Message>, Array<Mail::Message>)] inbox, sent.
      def cycling_list
        topics = ['Sunday ride to Nuuksio', 'Winter tyres: studded or not?', 'Lost glove at Kamppi meeting point',
                  'Chain wax recommendations', 'Night ride along the shore', 'Club jerseys order',
                  'Bike lights that survive January', 'Gravel route around Espoo', 'Spring maintenance day',
                  'Commuting in slush']
        inbox = []
        sent = []
        topics.each_with_index do |topic, t|
          thread = []
          replies = 2 + @random.rand(3)
          (0..replies).each do |r|
            from = r == replies && t.even? ? @facts.person(:owner) : RIDERS.fetch((t + r) % RIDERS.size)
            id = "riders-#{t}-#{r}"
            body = r.zero? ? "Hi all,\n\n#{topic.downcase}: who's in, and any thoughts?\n" : "#{list_reply(r)}\n"
            msg = plain(from, id, day: -100 + (t * 9) + r, subject: r.zero? ? "[riders] #{topic}" : "Re: [riders] #{topic}",
                                  body: body, to: "Helsinki Cycling <#{LIST}>", thread: thread)
            msg['List-Id'] = "Helsinki Cycling <#{LIST.sub('@', '.')}>"
            (from == @facts.person(:owner) ? sent : inbox) << msg
            thread << msg.message_id
          end
        end
        [inbox, sent]
      end

      # @return [String]
      def list_reply(n)
        ['Count me in.', 'I can bring a spare tube or two.', "Can't make it this time, have fun!",
         'Studded, every year since I slid into a tram stop.', 'Leaving from the usual place at 9?'].fetch(n % 5)
      end

      # @return [Mail::Message] a plain-text message.
      def plain(from, id, day:, subject:, body:, to: nil, thread: [])
        message(from, id, day: day, subject: subject, top: Mime.text(body), to: to, thread: thread)
      end

      # @return [Mail::Message]
      def message(from, id, day:, subject:, top:, to: nil, thread: [])
        message = Mail.new
        message.from = from
        message.to = to || @facts.person(:owner)
        hour = 6 + @random.rand(16)
        message.date = Demo.local_time(@facts.date([day, 0].min), format('%<h>02d:%<m>02d', h: hour, m: @random.rand(60)))
        message.message_id = "<noise-#{id}@#{Mail::Address.new(from).domain}>"
        message.subject = subject
        unless thread.empty?
          message.in_reply_to = "<#{thread.last}>"
          message.references = thread.map { |m| "<#{m}>" }.join(' ')
        end
        Mime.finish(message, top, id)
      end
    end
  end
end
