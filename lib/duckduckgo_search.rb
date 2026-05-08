# frozen_string_literal: true

require "faraday"
require "nokogiri"
require "uri"

module DuckDuckGoSearch
  ENDPOINT = "https://html.duckduckgo.com/html/".freeze
  USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
               "(KHTML, like Gecko) Chrome/120.0 Safari/537.36".freeze
  DEFAULT_MAX_RESULTS = 10

  def self.search(query, max_results: DEFAULT_MAX_RESULTS)
    cleaned = query.to_s.strip.gsub(/\s+/, " ")
    raise ArgumentError, "query is empty" if cleaned.empty?

    response = Faraday.get(ENDPOINT, { q: cleaned }, { "User-Agent" => USER_AGENT })
    raise "DuckDuckGo request failed: #{response.status} #{response.body}" unless response.success?

    parse(response.body, max_results: max_results)
  end

  def self.parse(html, max_results: DEFAULT_MAX_RESULTS)
    doc = Nokogiri::HTML(html)
    results = doc.css("div.result.web-result").take(max_results).filter_map do |node|
      title_link = node.at_css("a.result__a")
      next nil if title_link.nil?

      snippet = node.at_css("a.result__snippet")
      {
        title: title_link.text.strip,
        href: extract_url(title_link["href"]),
        body: snippet&.text&.strip.to_s
      }
    end

    return "No results found." if results.empty?

    "## Search Results\n\n" + results.map { |r| "[#{r[:title]}](#{r[:href]})\n#{r[:body]}" }.join("\n\n")
  end

  def self.extract_url(href)
    return href if href.nil? || href.empty?

    uri = URI.parse(href.start_with?("//") ? "https:#{href}" : href)
    return href unless uri.host&.end_with?("duckduckgo.com") && uri.path == "/l/"

    params = URI.decode_www_form(uri.query.to_s).to_h
    params["uddg"] || href
  rescue URI::InvalidURIError
    href
  end
end
