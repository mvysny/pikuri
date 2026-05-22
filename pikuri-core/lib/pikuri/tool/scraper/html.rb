# frozen_string_literal: true

require 'json'
require 'nokogiri'
require 'readability'
require 'reverse_markdown'

module Pikuri
  class Tool
    module Scraper
      # HTML → Markdown extractor used by {Simple.visit} when the fetched
      # response carries an HTML content-type.
      #
      # Always renders both views of the page when available:
      #
      # 1. JSON-LD section. Any +<script type="application/ld+json">+ node
      #    whose +@type+ matches a substantive schema.org content type
      #    (Product, Article, Recipe, ...) is rendered as a header — title,
      #    metadata bullets (brand, SKU, price, rating, author, published),
      #    and the +articleBody+/+description+ copy when present.
      # 2. Readability section. The page is run through +Readability+ +
      #    +reverse_markdown+, with a +<main>+/+<article>+ fallback for
      #    pages whose content sits mostly outside +<p>+ tags.
      #
      # Concatenated with a horizontal rule, so the LLM gets both the
      # structured metadata and the rendered body and can pick whichever
      # is more useful for the task. Trades some duplication (when a
      # publisher embeds the article body in JSON-LD AND in HTML) for
      # fewer type-based heuristics on which branch should win — the
      # earlier "is this Article's +description+ a teaser or the real
      # body?" carve-out is no longer needed because both end up in
      # the output regardless.
      #
      # Pure parser — no I/O. {.extract} takes an HTML string and returns
      # Markdown, so tests can drive it against fixture HTML without a
      # network round-trip.
      module HTML
        # @return [Array<String>] schema.org +@type+ values that we treat
        #   as "the primary entity of this page" when picking a JSON-LD
        #   node to render. Order does not matter — the first matching
        #   node wins. Skips noise nodes (Organization, BreadcrumbList,
        #   WebSite, ...) that ship on most pages but carry no page
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

        # @return [Float] minimum +<main>+/+<article>+ to Readability
        #   text-length ratio that triggers the semantic-container
        #   fallback in {.readability_to_markdown}. Picked low enough to
        #   catch the failure mode (Readability collapsing a page that
        #   uses divs/lists instead of +<p>+ — e.g. +vaadin.com/company+,
        #   ~5x) but high enough that pages where both produce
        #   comparable output keep Readability's noise filtering.
        MAIN_FALLBACK_RATIO = 2.0

        # @return [Integer] minimum text length the
        #   +<main>+/+<article>+ container must hold before the fallback
        #   in {.readability_to_markdown} can fire. Below this, the
        #   ratio comparison is dominated by noise and we'd swap on
        #   tiny pages where Readability is doing the right thing.
        MAIN_FALLBACK_MIN_CHARS = 500

        # Render +html+ as Markdown by emitting both the JSON-LD section
        # (when an interesting node is present) and the readability /
        # +<main>+ section, joined by a horizontal rule. Either section
        # may be missing — pages with no JSON-LD return only the
        # readability output, and a malformed page with no extractable
        # body returns only the JSON-LD render.
        #
        # @param html [String] HTML document body
        # @return [String] Markdown representation
        def self.extract(html)
          sections = [jsonld_section(html), readability_to_markdown(html)]
          sections.reject! { |s| s.nil? || s.strip.empty? }
          sections.join("\n\n---\n\n")
        end

        # Pick the first JSON-LD node whose +@type+ matches one of
        # {INTERESTING_TYPES} and render it as Markdown. Returns +nil+
        # when no such node exists, in which case {.extract} emits only
        # the readability section.
        #
        # No content-field gating: a node carrying just +name+/+author+/
        # +datePublished+ still renders (as a metadata-only header),
        # because the readability pass independently produces the page
        # body. That is the trade-off that lets us drop the type-based
        # "is this teaser or article copy?" heuristics — duplication is
        # acceptable when both views are available, and the LLM can
        # pick whichever it needs.
        #
        # @param html [String] HTML document body
        # @return [String, nil] Markdown render of the picked JSON-LD
        #   node, or +nil+ when nothing matched
        def self.jsonld_section(html)
          node = parse_jsonld(html).find do |n|
            Array(n['@type']).any? { |t| INTERESTING_TYPES.include?(t) }
          end
          node ? jsonld_to_markdown(node) : nil
        end

        # Collect every JSON-LD payload embedded in +html+, flattening
        # +@graph+ wrappers so callers see one flat array of schema.org
        # nodes. Malformed JSON blocks are silently skipped — sites
        # frequently ship broken JSON-LD and we only need at least one
        # parseable block.
        #
        # @param html [String] HTML document body
        # @return [Array<Hash>] parsed JSON-LD nodes; possibly empty
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

        # Render a single JSON-LD +node+ as Markdown: a top-level title
        # from +name+/+headline+, a bullet list of common useful fields
        # (brand, SKU, price, rating, author, published date, ...), the
        # body copy, and the lead image.
        #
        # When the node carries +articleBody+ (the full publisher-supplied
        # article text), that wins over +description+ — the description
        # is typically a lede teaser and would just repeat the article's
        # opening lines.
        #
        # @param node [Hash] JSON-LD node, typically picked by
        #   {.jsonld_section}
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

        # Run +Readability+ over +html+ to isolate the main content node,
        # then convert that to Markdown via +reverse_markdown+. The page
        # +<title>+ is rendered as a top-level heading.
        #
        # When the page uses semantic HTML5 (+<main>+ or +<article>+) but
        # leaves most of its content outside +<p>+ tags — divs, lists,
        # spans — Readability's paragraph-density scoring collapses the
        # extraction to a sliver of the page. In that case we render the
        # +<main>+/+<article>+ container directly. The fallback only
        # fires when the container holds substantially more text than
        # Readability picked up (see {MAIN_FALLBACK_RATIO} /
        # {MAIN_FALLBACK_MIN_CHARS}); on pages where both agree we keep
        # Readability so its noise filtering still strips nav/ads/etc.
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

        # If +html+ has a +<main>+ or +<article>+ element holding
        # substantially more text than Readability extracted, return that
        # container's HTML so the caller can render it instead. Returns
        # +nil+ when the fallback should not fire — when there is no
        # semantic container, when it's too small to be meaningful, or
        # when Readability's output is already comparable.
        #
        # @param html [String] full HTML document body, used to locate
        #   the +<main>+/+<article>+ container
        # @param readability_html [String] HTML produced by
        #   +Readability::Document#content+, used as the comparison
        #   baseline
        # @return [String, nil] container HTML when the fallback should
        #   fire, +nil+ otherwise
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

        # JSON-LD fields can be a string, hash, or array of either.
        # Normalize to a single hash (the first one if it's a list) so
        # callers can +.dig+ safely.
        #
        # @param value [Object] raw JSON-LD field value
        # @return [Hash] empty hash when +value+ does not contain a hash
        def self.first_obj(value)
          value = value.first if value.is_a?(Array)
          value.is_a?(Hash) ? value : {}
        end
        private_class_method :first_obj

        # Same idea as {.first_obj} but preserves a bare string (e.g.
        # +brand: "Apple"+) instead of replacing it with +{}+.
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
end
