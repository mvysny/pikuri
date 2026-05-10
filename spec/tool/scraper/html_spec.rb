# frozen_string_literal: true

require 'tool/scraper/html'

# Exercise the JSON-LD vs. readability decision in +HTML.extract+
# directly. Each example feeds a small HTML fixture and asserts which
# path won.
RSpec.describe Tool::Scraper::HTML, '.extract' do
  it 'falls through to readability when JSON-LD has no content fields (Wikipedia-shape)' do
    # Wikipedia ships an Article JSON-LD block with only metadata —
    # name, author, datePublished, dateModified — and the actual page
    # content lives in the HTML body. Without the content-field gate
    # in best_jsonld_node, the scraper would emit a few lines of
    # metadata and drop the article.
    html = <<~HTML
      <html>
        <head>
          <title>X86 - Wikipedia</title>
          <script type="application/ld+json">
            {
              "@context": "https://schema.org",
              "@type": "Article",
              "name": "X86",
              "author": { "@type": "Organization", "name": "Contributors to Wikimedia projects" },
              "datePublished": "2001-10-31T13:12:04Z"
            }
          </script>
        </head>
        <body>
          <article>
            <h1>x86</h1>
            <p>x86 is a family of complex instruction set computer instruction set architectures
            initially developed by Intel based on the Intel 8086 microprocessor and its 8088 variant.</p>
            <p>The 8086 was introduced in 1978 as a fully 16-bit extension of Intel's 8-bit 8080
            microprocessor, with memory segmentation as a solution for addressing more memory than
            can be covered by a plain 16-bit address.</p>
          </article>
        </body>
      </html>
    HTML

    out = described_class.extract(html)
    assert_includes out, 'x86 is a family of complex instruction set computer'
    assert_includes out, '8086 was introduced in 1978'
    refute_includes out, '**Author:**',
                    'JSON-LD path should not have fired — that block has no description/articleBody'
  end

  it 'uses the JSON-LD fast path when an Article carries a description' do
    html = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">
            {
              "@context": "https://schema.org",
              "@type": "Article",
              "name": "Hello",
              "description": "Short article summary that the LLM actually wants.",
              "author": "Jane Doe"
            }
          </script>
        </head>
        <body><p>chrome and ads</p></body>
      </html>
    HTML

    out = described_class.extract(html)
    assert_includes out, '# Hello'
    assert_includes out, 'Short article summary that the LLM actually wants.'
    assert_includes out, '**Author:** Jane Doe'
  end

  it 'uses the JSON-LD fast path when a Product carries offers (no description needed)' do
    html = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">
            {
              "@context": "https://schema.org",
              "@type": "Product",
              "name": "Widget",
              "sku": "W-1",
              "offers": { "@type": "Offer", "price": "9.99", "priceCurrency": "USD" }
            }
          </script>
        </head>
        <body><p>chrome and ads</p></body>
      </html>
    HTML

    out = described_class.extract(html)
    assert_includes out, '# Widget'
    assert_includes out, '**Price:** 9.99 USD'
    assert_includes out, '**SKU:** W-1'
  end
end
