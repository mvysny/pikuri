# frozen_string_literal: true

require 'faraday'
require 'json'
require 'nokogiri'
require 'readability'
require 'reverse_markdown'
require 'uri'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order.
class Tool
  module Scraper
    # Plain HTTP scraper: GET the URL with a real-browser User-Agent,
    # follow redirects, and render the response body as Markdown for the
    # agent loop.
    #
    # Two-stage strategy:
    #
    # 1. JSON-LD fast path. Many sites embed
    #    +<script type="application/ld+json">+ blocks describing the
    #    primary entity (Product, Article, Recipe, ...). When such a node
    #    is present we render it directly. This handles SPA pages whose
    #    visible markup is largely empty, and produces tight output on
    #    product/recipe pages where the LLM mostly wants the structured
    #    fields.
    # 2. Readability fallback. If no useful JSON-LD is found, run
    #    +Readability+ over the HTML to isolate the main content node,
    #    then convert it to Markdown via +reverse_markdown+.
    #
    # Split into a thin HTTP fetch ({.fetch}) and a pure parser
    # ({.extract}) so tests can exercise the parser against fixture HTML
    # without hitting the network. "Simple" because everything happens
    # in one Faraday GET — no headless browser, no JS execution.
    module Simple
      # @return [String] User-Agent sent with each request; many sites
      #   reject requests with no UA or an obvious bot UA
      USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' \
                   '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
      # @return [Integer] maximum number of HTTP redirects to follow
      #   before giving up
      MAX_REDIRECTS = 5
      # @return [Integer] connect timeout in seconds for the underlying
      #   Faraday request
      OPEN_TIMEOUT = 10
      # @return [Integer] read timeout in seconds for the underlying
      #   Faraday request
      READ_TIMEOUT = 20

      # @return [Array<String>] schema.org +@type+ values that we treat
      #   as "the primary entity of this page" when picking a JSON-LD
      #   node to render. Order does not matter — the first matching
      #   node wins.
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

      # Fetch +url+ and render its main content as Markdown.
      #
      # No caching here — every call hits the network. Callers that want
      # to memoize results should wrap this method themselves (see
      # {Tool::WebFetch.visit}, which does exactly that).
      #
      # @param url [String] absolute HTTP(S) URL of the page to download
      # @return [String] full Markdown representation of the page,
      #   uncapped — caller is responsible for any size limiting before
      #   feeding the result back to the LLM
      # @raise [ArgumentError] if too many redirects are encountered
      # @raise [RuntimeError] if the HTTP response is non-success or a
      #   redirect arrives without a +Location+ header
      def self.visit(url)
        extract(fetch(url))
      end

      # Download the body of +url+, manually following up to
      # {MAX_REDIRECTS} redirects. Faraday is configured with no
      # middleware so behavior here mirrors the rest of the codebase
      # (see +Tool::Search::DuckDuckGo.search+).
      #
      # @param url [String] absolute HTTP(S) URL to fetch
      # @param limit [Integer] redirects remaining; recurses with
      #   +limit - 1+ on each 3xx
      # @return [String] response body for the final 2xx response
      # @raise [ArgumentError] if +limit+ reaches zero
      # @raise [RuntimeError] on non-2xx/3xx responses or 3xx without a
      #   +Location+ header
      def self.fetch(url, limit: MAX_REDIRECTS)
        raise ArgumentError, "too many redirects fetching #{url}" if limit.zero?

        response = Faraday.new(request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT }).get(url) do |req|
          req.headers['User-Agent'] = USER_AGENT
          req.headers['Accept']     = 'text/html,application/xhtml+xml'
        end

        case response.status
        when 200..299
          response.body
        when 300..399
          location = response.headers['location']
          raise "HTTP #{response.status} from #{url} with no Location header" if location.nil? || location.empty?

          fetch(URI.join(url, location).to_s, limit: limit - 1)
        else
          raise "HTTP #{response.status} fetching #{url}: #{response.body}"
        end
      end

      # Render +html+ as Markdown, preferring the JSON-LD fast path and
      # falling back to readability extraction.
      #
      # @param html [String] HTML document body
      # @return [String] Markdown representation
      def self.extract(html)
        nodes = parse_jsonld(html)
        if (node = best_jsonld_node(nodes))
          return jsonld_to_markdown(node)
        end

        readability_to_markdown(html)
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

      # Pick the most useful node out of a flat JSON-LD list — the first
      # one whose +@type+ matches {INTERESTING_TYPES}. Returns +nil+
      # when none match, signalling that the readability fallback
      # should run.
      #
      # @param nodes [Array<Hash>] JSON-LD nodes from {.parse_jsonld}
      # @return [Hash, nil]
      def self.best_jsonld_node(nodes)
        nodes.find do |n|
          types = Array(n['@type'])
          types.any? { |t| INTERESTING_TYPES.include?(t) }
        end
      end

      # Render a single JSON-LD +node+ as Markdown: a top-level title
      # from +name+/+headline+, a bullet list of common useful fields
      # (brand, SKU, price, rating, author, published date, ...), the
      # description paragraph, and the lead image.
      #
      # @param node [Hash] JSON-LD node, typically picked by
      #   {.best_jsonld_node}
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

        if (desc = node['description'])
          out << "#{desc}\n\n"
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
      # @param html [String] HTML document body
      # @return [String] Markdown representation
      def self.readability_to_markdown(html)
        doc = Readability::Document.new(
          html,
          tags: READABILITY_TAGS,
          attributes: READABILITY_ATTRS,
          remove_empty_nodes: true
        )

        title = doc.title
        body  = ReverseMarkdown.convert(doc.content, unknown_tags: :bypass, github_flavored: true)

        out = +''
        out << "# #{title.strip}\n\n" if title && !title.strip.empty?
        out << body
        out
      end

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
