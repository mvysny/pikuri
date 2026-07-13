# frozen_string_literal: true

require 'json'
require 'nokogiri'
require 'readability'
require 'reverse_markdown'

module Pikuri
  module Extractor
    # HTML → Markdown extractor.
    #
    # Matched by content-type only (+text/html+ / +application/xhtml+xml+) —
    # no byte sniff: the web path always has the header, and sniffing would
    # route a +Workspace::Read+ of a local +.html+ *source* file through
    # readability when the developer wants the source. Local HTML stays on the
    # {Passthrough} arm.
    #
    # Renders both views when available, concatenated with a horizontal rule,
    # so the LLM gets structured metadata and rendered body and picks whichever
    # fits:
    #
    # 1. JSON-LD — the first +<script type="application/ld+json">+ node whose
    #    +@type+ is a substantive schema.org type ({INTERESTING_TYPES}),
    #    rendered as title + metadata bullets + body copy.
    # 2. Readability — +Readability+ + +reverse_markdown+, with a
    #    +<main>+/+<article>+ fallback for pages whose content sits outside
    #    +<p>+ tags.
    #
    # Emitting both trades some duplication (a body embedded in JSON-LD *and*
    # HTML) for dropping type-based "teaser or real body?" heuristics.
    module HTML
      # @return [Array<String>] content-types this extractor claims.
      CONTENT_TYPES = %w[text/html application/xhtml+xml].freeze

      # @return [Array<String>] schema.org +@type+ values treated as the page's
      #   primary entity when picking a JSON-LD node (first match wins). Skips
      #   noise nodes (Organization, BreadcrumbList, WebSite) that carry no
      #   content.
      INTERESTING_TYPES = %w[
        Product Article NewsArticle BlogPosting Recipe Event Book Movie
      ].freeze

      # @return [Array<String>] HTML tags preserved by the readability
      #   pass. Anything outside this list is stripped before Markdown
      #   conversion.
      READABILITY_TAGS = %w[
        h1 h2 h3 h4 h5 h6 p div span ul ol li blockquote pre code a img
        strong em b i br hr table thead tbody tr td th
      ].freeze

      # @return [Array<String>] HTML attributes preserved by the
      #   readability pass; everything else (class, id, style, data-*)
      #   is dropped before Markdown conversion
      READABILITY_ATTRS = %w[href src alt title].freeze

      # @return [Float] minimum +<main>+/+<article>+-to-Readability text-length
      #   ratio that triggers the semantic-container fallback in
      #   {.readability_to_markdown}. Low enough to catch Readability collapsing
      #   a div/list-based page (vaadin.com/company, ~5x), high enough to keep
      #   its noise filtering where both outputs are comparable.
      MAIN_FALLBACK_RATIO = 2.0

      # @return [Integer] minimum text length the +<main>+/+<article>+ container
      #   must hold before the {.readability_to_markdown} fallback can fire —
      #   below it the ratio is noise-dominated and would swap on tiny pages.
      MAIN_FALLBACK_MIN_CHARS = 500

      # @return [Symbol] {Page#kind} tag.
      def self.kind
        :html
      end

      # @param sample [String] leading bytes of the content (unused —
      #   see the no-sniff rationale in the module doc).
      # @param content_type [String, nil] normalized content-type.
      # @return [Boolean]
      def self.matches?(sample:, content_type:)
        CONTENT_TYPES.include?(content_type)
      end

      # Render the HTML behind +io+ as Markdown: the JSON-LD section (when an
      # interesting node is present) and the readability/+<main>+ section,
      # joined by a horizontal rule. Either may be missing.
      #
      # @param io [IO, StringIO] IO over the HTML document.
      # @return [String] Markdown representation
      def self.extract(io)
        html = io.read
        sections = [jsonld_section(html), readability_to_markdown(html)]
        sections.reject! { |s| s.nil? || s.strip.empty? }
        sections.join("\n\n---\n\n")
      end

      # Pick the first JSON-LD node whose +@type+ is in {INTERESTING_TYPES} and
      # render it. +nil+ when none matches. No content-field gating — a
      # metadata-only node (name/author/date) still renders, since the
      # readability pass independently produces the body.
      #
      # @param html [String] HTML document body
      # @return [String, nil] Markdown render, or +nil+ when nothing matched
      def self.jsonld_section(html)
        node = parse_jsonld(html).find do |n|
          Array(n['@type']).any? { |t| INTERESTING_TYPES.include?(t) }
        end
        node ? jsonld_to_markdown(node) : nil
      end

      # Collect every JSON-LD payload in +html+, flattening +@graph+ wrappers
      # into one flat array. Malformed JSON blocks are skipped (sites ship
      # broken JSON-LD; one parseable block suffices).
      #
      # @param html [String] HTML document body
      # @return [Array<Hash>] parsed nodes; possibly empty
      def self.parse_jsonld(html)
        doc = Nokogiri::HTML(html)
        blobs = doc.css('script[type="application/ld+json"]').map(&:text)

        blobs.flat_map do |raw|
          parsed = begin
            JSON.parse(raw)
          rescue JSON::ParserError
            nil
          end
          next [] unless parsed

          nodes = parsed.is_a?(Array) ? parsed : [parsed]
          nodes.flat_map { |n| n['@graph'].is_a?(Array) ? n['@graph'] : [n] }
        end
      end

      # Render a JSON-LD +node+ as Markdown: title from +name+/+headline+, a
      # bullet list of common fields (brand, SKU, price, rating, author, date),
      # body copy, and the lead image. +articleBody+ wins over +description+
      # (the description is usually a lede teaser).
      #
      # @param node [Hash] JSON-LD node
      # @return [String] Markdown representation
      def self.jsonld_to_markdown(node)
        out = +''
        name = node['name'] || node['headline']
        out << "# #{name}\n\n" if name

        offer  = first_obj(node['offers'])
        rating = first_obj(node['aggregateRating'])
        brand  = first_obj_or_string(node['brand'])
        author = first_obj_or_string(node['author'])

        brand_name  = brand.is_a?(Hash)  ? brand['name']  : brand
        author_name = author.is_a?(Hash) ? author['name'] : author

        fields = {
          'Brand'        => brand_name,
          'SKU'          => node['sku'],
          'GTIN'         => node['gtin13'] || node['gtin'],
          'Price'        => [offer['price'], offer['priceCurrency']].compact.join(' '),
          'Availability' => offer['availability'],
          'Rating'       => rating['ratingValue'],
          'Reviews'      => rating['reviewCount'],
          'Author'       => author_name,
          'Published'    => node['datePublished']
        }.reject { |_, v| v.nil? || v.to_s.strip.empty? }

        unless fields.empty?
          fields.each { |k, v| out << "- **#{k}:** #{v}\n" }
          out << "\n"
        end

        if (body = node['articleBody'] || node['description'])
          out << "#{body}\n\n"
        end

        if (img = node['image'])
          img = img.first if img.is_a?(Array)
          img = img['url'] if img.is_a?(Hash)
          out << "![image](#{img})\n\n" if img
        end

        out
      end

      # Run +Readability+ over +html+, convert to Markdown via
      # +reverse_markdown+, +<title>+ as a top-level heading. When the page
      # uses HTML5 semantics (+<main>+/+<article>+) but leaves content outside
      # +<p>+ tags, Readability's paragraph-density scoring collapses the
      # extraction; then the container is rendered directly. The fallback fires
      # only when the container holds substantially more text (see
      # {MAIN_FALLBACK_RATIO} / {MAIN_FALLBACK_MIN_CHARS}).
      #
      # @param html [String] HTML document body
      # @return [String] Markdown representation
      def self.readability_to_markdown(html)
        rdoc = Readability::Document.new(
          html,
          tags: READABILITY_TAGS,
          attributes: READABILITY_ATTRS,
          remove_empty_nodes: true
        )
        readability_html = rdoc.content
        title = rdoc.title

        body_html = main_fallback_html(html, readability_html) || readability_html
        body = ReverseMarkdown.convert(body_html, unknown_tags: :bypass, github_flavored: true)

        out = +''
        out << "# #{title.strip}\n\n" if title && !title.strip.empty?
        out << body
        out
      end

      # Return the +<main>+/+<article>+ container's HTML when it holds
      # substantially more text than Readability extracted, else +nil+ (no
      # container, too small, or Readability comparable).
      #
      # @param html [String] full HTML document body
      # @param readability_html [String] +Readability::Document#content+ output,
      #   the comparison baseline
      # @return [String, nil] container HTML when the fallback should fire
      def self.main_fallback_html(html, readability_html)
        doc = Nokogiri::HTML(html)
        container = doc.at_css('main') || doc.at_css('article')
        return nil unless container

        container_text_len = container.text.gsub(/\s+/, ' ').strip.length
        return nil if container_text_len < MAIN_FALLBACK_MIN_CHARS

        readability_text_len = Nokogiri::HTML(readability_html).text.gsub(/\s+/, ' ').strip.length
        return nil if container_text_len < MAIN_FALLBACK_RATIO * readability_text_len

        container.to_html
      end
      private_class_method :main_fallback_html

      # Normalize a JSON-LD field (string, hash, or array of either) to a single
      # hash (first if a list) so callers can +.dig+ safely.
      #
      # @param value [Object] raw JSON-LD field value
      # @return [Hash] empty hash when +value+ contains no hash
      def self.first_obj(value)
        value = value.first if value.is_a?(Array)
        value.is_a?(Hash) ? value : {}
      end
      private_class_method :first_obj

      # Like {.first_obj} but preserves a bare string (e.g. +brand: "Apple"+)
      # instead of replacing it with +{}+.
      #
      # @param value [Object] raw JSON-LD field value
      # @return [String, Hash, nil]
      def self.first_obj_or_string(value)
        value = value.first if value.is_a?(Array)
        value
      end
      private_class_method :first_obj_or_string
    end
  end
end
