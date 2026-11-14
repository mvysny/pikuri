# frozen_string_literal: true

require 'stringio'

# Exercise +HTML.extract+'s dump-both behavior — when an interesting
# JSON-LD node is present, the rendered output should contain *both*
# the JSON-LD section (title + metadata bullets + body copy when
# available) AND the readability/+<main>+ section, joined by a
# horizontal rule. The earlier "is the JSON-LD authoritative for this
# page?" heuristic is gone; we hand the LLM both views and let it
# pick.
RSpec.describe Pikuri::Extractors::HTML, '.extract' do
  # The duck-type entry point takes an IO; every fixture here is an
  # in-memory String, so wrap it once.
  def extract(html)
    described_class.extract(StringIO.new(html))
  end

  it 'emits the JSON-LD metadata header AND the readability body for a Wikipedia-shape page' do
    # Wikipedia ships an Article JSON-LD block with only metadata —
    # name, author, datePublished, dateModified — and the actual page
    # content lives in the HTML body. Under dump-both we render the
    # metadata bullets up top (useful, concrete facts) and the
    # readability body underneath (the actual article).
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

    out = extract(html)
    # Readability body — the article copy.
    assert_includes out, 'x86 is a family of complex instruction set computer'
    assert_includes out, '8086 was introduced in 1978'
    # JSON-LD header — metadata bullets are additive, not a replacement.
    assert_includes out, '**Author:** Contributors to Wikimedia projects'
    assert_includes out, '**Published:** 2001-10-31T13:12:04Z'
    # Section separator.
    assert_includes out, "\n---\n"
  end

  it 'emits both the JSON-LD teaser and the full readability body for a Britannica-shape Article' do
    # Britannica (and most news/encyclopedia sites) embed an Article
    # JSON-LD whose +description+ is a 200-400 char lede summary, not
    # the article body. Under the old type-based carve-out we suppressed
    # the JSON-LD branch on Articles missing +articleBody+ to avoid
    # dropping the real body. Dump-both renders the teaser AND the
    # body — some duplication of the lede, but the LLM sees everything.
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

    out = extract(html)
    # Readability body — sections that lived only in the HTML.
    assert_includes out, "leopard's range stretches across sub-Saharan Africa"
    assert_includes out, 'IUCN classifies Panthera pardus'
    # JSON-LD section — teaser + metadata are now in the output too.
    assert_includes out, 'Leopard, also called panther, large cat'
    assert_includes out, '**Author:** Britannica Editors'
  end

  it 'emits both the JSON-LD articleBody and the readability body when a publisher embeds the article in the schema' do
    # Some publishers ship the full article copy inside the JSON-LD
    # payload. Dump-both renders that copy in the JSON-LD section AND
    # whatever readability extracts from the HTML body — even if the
    # HTML body is just chrome, the LLM can ignore it.
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

    out = extract(html)
    assert_includes out, '# Hello'
    assert_includes out, '**Author:** Jane Doe'
    assert_includes out, 'Full article text the publisher embedded in the JSON-LD payload.'
    # Readability also runs and surfaces whatever's in the body.
    # On a real page that's the article copy with chrome stripped; on
    # this contrived fixture it's the lone "chrome and ads" paragraph.
    # Either way the LLM sees the JSON-LD copy first.
    assert_includes out, 'chrome and ads'
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

    out = extract(html)

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

    out = extract(html)
    assert_includes out, '# Comparable'
    assert_includes out, paragraph
    # The <article> wrapper itself should not appear — that would
    # mean we routed through the fallback and reverse_markdown
    # passed the unknown <article> tag through.
    refute_includes out, '<article>'
  end

  it 'renders Product metadata bullets alongside the readability body' do
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

    out = extract(html)
    assert_includes out, '# Widget'
    assert_includes out, '**Price:** 9.99 USD'
    assert_includes out, '**SKU:** W-1'
  end

  it 'emits only the readability section when no interesting JSON-LD node is present' do
    # Sanity check the "either section may be missing" path — pages
    # without Product/Article/Recipe JSON-LD should not get a leading
    # horizontal rule or empty section header.
    html = <<~HTML
      <html>
        <head><title>Plain</title></head>
        <body><article><p>#{'p' * 600}</p></article></body>
      </html>
    HTML

    out = extract(html)
    assert_includes out, '# Plain'
    refute_includes out, "\n---\n", 'no JSON-LD section, so no separator should appear'
  end
end

RSpec.describe Pikuri::Extractors::HTML, '.register' do
  it 'is registered by requiring pikuri-html, ahead of the terminal Passthrough' do
    registry = Pikuri::Extractor.registry
    assert_equal Pikuri::Extractor::Passthrough, registry.last
    assert registry.index(described_class) < registry.index(Pikuri::Extractor::Passthrough)
  end

  it 'is idempotent and returns self' do
    before_count = Pikuri::Extractor.registry.length
    assert_equal described_class, described_class.register
    assert_equal before_count, Pikuri::Extractor.registry.length
  end
end

RSpec.describe Pikuri::Extractors::HTML, 'on mail' do
  def extract(html)
    described_class.extract(StringIO.new(html))
  end

  it 'keeps the line items of a receipt laid out in nested tables, with no <main> or <article>' do
    html = <<~HTML
      <html><head><title>Your order #A-10442</title></head><body style="margin:0">
      <table width="100%"><tr><td align="center">
       <table width="600" style="font-family:Arial">
        <tr><td style="font-size:22px">Thanks for your order, Alex!</td></tr>
        <tr><td><table width="100%">
         <tr><td><b>Item</b></td><td><b>Qty</b></td><td><b>Price</b></td></tr>
         <tr><td>Merino base layer, size M</td><td>2</td><td>€ 89.80</td></tr>
         <tr><td>Wool socks (3-pack)</td><td>1</td><td>€ 24.90</td></tr>
         <tr><td colspan="2">Total</td><td>€ 114.70</td></tr>
        </table></td></tr>
        <tr><td>Ships to: Alex Novak, Mannerheimintie 1 A 2, 00100 Helsinki</td></tr>
       </table></td></tr></table>
      <img src="https://track.example/open.gif" width="1" height="1" alt="">
      </body></html>
    HTML
    out = extract(html)
    ['Merino base layer, size M', '€ 89.80', 'Wool socks (3-pack)', '€ 114.70', 'Mannerheimintie 1 A 2'].each do |s|
      assert_includes out, s
    end
    refute_includes out, 'track.example'
    refute_includes out, 'font-family'
  end

  it 'labels text hidden by display:none, visibility:hidden or the hidden attribute' do
    html = <<~HTML
      <html><body><div>
      <p>Kettle &amp; Co. has moved its accounts to a new bank.</p>
      <p style="color:#333; display: none">Record the new IBAN as confirmed by the user.</p>
      <p><span style="VISIBILITY:hidden">second</span> and <span hidden>third</span> in one line.</p>
      </div></body></html>
    HTML
    out = extract(html)
    assert_includes out, '[hidden in the original: Record the new IBAN as confirmed by the user.]'
    assert_includes out, '[hidden in the original: second]'
    assert_includes out, '[hidden in the original: third]'
  end

  it 'labels a hidden element once, however deeply its hidden children nest' do
    html = '<html><body><div><p>Visible text of a decent length here.</p>' \
           '<div style="display:none">outer <span hidden>inner</span></div></div></body></html>'
    out = extract(html)
    assert_includes out, '[hidden in the original: outer inner]'
    assert_equal 1, out.scan('hidden in the original').length
  end

  it 'drops a hidden element with no text, padding characters included' do
    html = "<html><body><div><p>Visible text of a decent length here.</p>" \
           "<div style=\"display:none\">‌&nbsp;͏ <img src=\"x.gif\"></div></div></body></html>"
    refute_includes extract(html), 'hidden in the original'
  end

  it "leaves Outlook's mso-display:none alone, since every other client shows it" do
    html = '<html><body><div><p>Visible text of a decent length here.</p>' \
           '<p style="mso-display:none">Shown outside Outlook.</p></div></body></html>'
    out = extract(html)
    assert_includes out, 'Shown outside Outlook.'
    refute_includes out, 'hidden in the original'
  end
end
