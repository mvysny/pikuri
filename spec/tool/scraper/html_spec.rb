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

  it 'falls through to readability when an Article ships only a teaser description (Britannica-shape)' do
    # Britannica (and most news/encyclopedia sites) embed an Article
    # JSON-LD whose +description+ is a 200-400 char lede summary, not
    # the article body. Treating that as the canonical content drops
    # the whole page — the actual sections (Distribution, Natural
    # history, Conservation status, ...) live in the HTML body. So
    # for Article-shaped types we require +articleBody+ specifically;
    # a bare +description+ is not enough to fire the fast path.
    html = <<~HTML
      <html>
        <head>
          <title>Leopard | Description, Habitat, &amp; Facts | Britannica</title>
          <script type="application/ld+json">
            {
              "@context": "https://schema.org",
              "@type": "Article",
              "headline": "leopard",
              "description": "Leopard, also called panther, large cat closely related to the lion, tiger, and jaguar.",
              "author": { "@type": "Organization", "name": "Britannica Editors" },
              "datePublished": "1999-05-04T00:00:00Z"
            }
          </script>
        </head>
        <body>
          <article>
            <h1>leopard</h1>
            <h2>Distribution</h2>
            <p>The leopard's range stretches across sub-Saharan Africa and into south and east Asia,
            with isolated populations in the Russian Far East and the Arabian Peninsula.</p>
            <h2>Conservation status</h2>
            <p>The IUCN classifies Panthera pardus as a vulnerable species, with the number of
            leopards worldwide estimated at several hundred thousand individuals.</p>
          </article>
        </body>
      </html>
    HTML

    out = described_class.extract(html)
    assert_includes out, "leopard's range stretches across sub-Saharan Africa"
    assert_includes out, 'IUCN classifies Panthera pardus'
    refute_includes out, '**Author:** Britannica Editors',
                    'JSON-LD fast path should not have fired — Article needs articleBody, not just description'
  end

  it 'uses the JSON-LD fast path when an Article carries an articleBody' do
    # When the JSON-LD really does carry the article copy (some
    # publishers ship the full body in the schema.org block), the
    # fast path is the right call — the structured fields are cleaner
    # than what Readability would extract.
    html = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">
            {
              "@context": "https://schema.org",
              "@type": "Article",
              "name": "Hello",
              "articleBody": "Full article text the publisher embedded in the JSON-LD payload.",
              "author": "Jane Doe"
            }
          </script>
        </head>
        <body><p>chrome and ads</p></body>
      </html>
    HTML

    out = described_class.extract(html)
    assert_includes out, '# Hello'
    assert_includes out, '**Author:** Jane Doe'
    assert_includes out, 'Full article text the publisher embedded in the JSON-LD payload.'
    refute_includes out, 'chrome and ads'
  end

  it 'falls back to <main> when Readability collapses a div/list-heavy page' do
    # Real-world capture of vaadin.com/company. The page renders its
    # main content using divs, lists and spans — zero <p> tags except
    # in one trailing "Sustainability" block. Readability's
    # paragraph-density scoring picks only that block (~500 chars of
    # markdown), missing the About us / Our values / Serving
    # customers sections. The <main> fallback should kick in and
    # surface the full page.
    html = File.read(File.expand_path('../../fixtures/vaadin_company.html', __dir__))

    out = described_class.extract(html)

    assert_includes out, '# Vaadin – The Company Behind the Full-Stack Java Platform'
    assert_includes out, '## About us'
    assert_includes out, 'Vaadin makes developing and modernizing Java-based applications'
    assert_includes out, '## Our values'
    assert_includes out, '## Choose the Herd'
    assert_includes out, '## Own the Solution'
    assert_includes out, '## Dare to Explore'
    assert_includes out, '## Serving customers globally'
    # And the original Sustainability block Readability did pick
    # should still be present, not lost in the swap:
    assert_includes out, '## Sustainability'
    assert_operator out.length, :>, 3000,
                    'expected the <main> fallback to surface the full page (Readability alone returns ~500 chars)'
  end

  it 'keeps Readability output when <article> text is comparable in length' do
    # The fallback ratio gate (container >= 2x readability) must not
    # fire on pages where Readability is already doing its job —
    # otherwise we'd lose its noise filtering on every semantic-HTML
    # page. This Wikipedia-shape document has its content inside
    # <article>, but Readability extracts essentially the same text,
    # so the fallback should stay quiet and leave the output alone.
    paragraph = 'x' * 600
    html = <<~HTML
      <html>
        <head><title>Comparable</title></head>
        <body>
          <article>
            <h1>Comparable</h1>
            <p>#{paragraph}</p>
          </article>
        </body>
      </html>
    HTML

    out = described_class.extract(html)
    assert_includes out, '# Comparable'
    assert_includes out, paragraph
    # The <article> wrapper itself should not appear — that would
    # mean we routed through the fallback and reverse_markdown
    # passed the unknown <article> tag through.
    refute_includes out, '<article>'
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
