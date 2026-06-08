# frozen_string_literal: true

module Pikuri
  # Renders attacker-controlled text safe to display, and reports *why*
  # it was unsafe.
  #
  # Every string an LLM composes is untrusted: a bash command, a tool
  # observation echoed back to the user, a description it wrote for a
  # confirmation prompt. A model that is broken — or, far more likely,
  # being driven by a prompt injection — can embed bytes that a terminal
  # acts on rather than prints: a carriage return that overwrites the
  # line the user just read, an ESC that recolors or repositions, a
  # backspace that erases, a bidirectional override that reorders text so
  # it reads differently than it runs, a zero-width character that hides
  # in plain sight, or a Cyrillic +а+ masquerading as a Latin +a+. The
  # whole point of a confirmation prompt collapses if the bytes the user
  # approves are not the bytes that execute.
  #
  # {.sanitize} is the one chrome-independent primitive every renderer
  # (terminal, TUI, web) routes through. It does two things and returns
  # both as a {Result}:
  #
  # 1. *Neutralize* — make the dangerous bytes visible without changing
  #    structure. Control bytes become +\xNN+, bidi/zero-width codepoints
  #    become +\u{NNNN}+, tab becomes +\t+. Newlines are preserved
  #    (multi-line commands are normal). This is *faithful, not
  #    beautifying*: it never collapses runs of whitespace or rewrites a
  #    tab to a space, because the user must see exactly what they are
  #    approving — a Makefile's leading tab stays visibly a tab. A web
  #    chrome composes +html_escape(sanitize(s).text)+; the HTML layer is
  #    the caller's, not ours.
  # 2. *Warn* — return a {Warning} per category detected, each a semantic
  #    record (kind + offending tokens + a plain-English explanation).
  #    Presentation is the chrome's: a terminal renders these bold yellow,
  #    a web client a banner. The {Warning} carries no color or markup.
  #
  # == Scope (deliberately closed)
  #
  # Detection covers the *invisibility / cursor-control / reordering*
  # attack classes completely, because each is a finite, enumerable set
  # of codepoints: C0 controls, C1 controls (a second ANSI introducer on
  # some emulators), DEL, the bidi overrides, and the zero-width
  # characters. On top of that, {.sanitize} flags *mixed-script tokens* —
  # a single word combining letters from Latin + Cyrillic + Greek, which
  # is the signature of a homoglyph spoof and has near-zero false
  # positives on real text (humans do not weld two alphabets inside one
  # word; +café+ is all-Latin, +Москва+ all-Cyrillic, only +Pаypal+ mixes).
  #
  # Two confusable classes are explicitly *out of scope*, because
  # detecting them needs Unicode confusables tables and produces heavy
  # false positives on legitimate multilingual text:
  #
  # * *Whole-script* homoglyphs — an entirely-Cyrillic string that merely
  #   looks Latin (no mixing to detect).
  # * *Single-symbol* confusables — the Greek question mark +;+ (U+037E)
  #   that looks like a semicolon, full-width forms, the division slash.
  #
  # "Solid" here means complete on the classes above, not exhaustive over
  # all of Unicode.
  module Sanitizer
    # One reason a piece of text was flagged, ready for a chrome to
    # render however it surfaces warnings (bold yellow line, web banner).
    #
    # * +kind+ — a {Symbol} category: +:backspace+, +:control_bytes+,
    #   +:bidi+, +:zero_width+, or +:mixed_script+.
    # * +offenders+ — the distinct offending tokens, in first-seen order:
    #   the escaped forms (+"\\x1b"+, +"\\u{202e}"+) for byte categories,
    #   the raw tokens (+"Pаypal"+) for +:mixed_script+.
    # * +explanation+ — a one-line, chrome-agnostic English summary of
    #   what the bytes can do.
    Warning = Data.define(:kind, :offenders, :explanation)

    # The output of {Sanitizer.sanitize}.
    #
    # * +text+ — the neutralized string, safe to print literally.
    # * +warnings+ — {Array}<{Warning}>, empty when nothing was flagged.
    Result = Data.define(:text, :warnings)

    # Bidirectional-override codepoints: the explicit LRO/RLO/PDF/LRE/RLE
    # set plus the isolate set (LRI/RLI/FSI/PDI). Reordering attacks.
    BIDI_OVERRIDES = [*0x202a..0x202e, *0x2066..0x2069].freeze

    # Zero-width and invisible codepoints: ZWSP, ZWNJ, ZWJ, and the BOM /
    # zero-width no-break space.
    ZERO_WIDTH = [0x200b, 0x200c, 0x200d, 0xfeff].freeze

    # Codepoints {.sanitize} rewrites: C0 controls including tab (U+0009)
    # but *excluding* newline (U+000A, which passes through untouched),
    # C1 controls + DEL (U+007F–009F), the zero-width set, and the bidi
    # overrides. Newline is the one control character a faithful render
    # must keep, so the C0 range is split around it.
    SUSPECT = /[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u200b-\u200d\u202a-\u202e\u2066-\u2069\ufeff]/

    # The three Latin-confusable scripts whose mixing inside one token
    # signals a homoglyph spoof. Punctuation, digits and spaces are the
    # +Common+ script and match none of these, so they never count toward
    # the "two distinct scripts" threshold.
    CONFUSABLE_SCRIPTS = { 'Latin' => /\p{Latin}/, 'Cyrillic' => /\p{Cyrillic}/, 'Greek' => /\p{Greek}/ }.freeze

    # Neutralize +text+ for literal display and report what was flagged.
    #
    # @param text [String] attacker-controlled text (an LLM-composed
    #   command, description, or tool observation), e.g.
    #   +"echo hi\rrm -rf /"+
    # @return [Result] the neutralized +text+ plus an {Array}<{Warning}>
    #   (empty when clean)
    def self.sanitize(text)
      backspace  = false
      control    = []
      bidi       = []
      zero_width = []

      clean = text.gsub(SUSPECT) do |ch|
        cp = ch.ord
        if cp == 0x09
          '\\t'
        elsif cp == 0x08
          backspace = true
          '\\x08'
        elsif BIDI_OVERRIDES.include?(cp)
          format('\\u{%04x}', cp).tap { |t| bidi << t }
        elsif ZERO_WIDTH.include?(cp)
          format('\\u{%04x}', cp).tap { |t| zero_width << t }
        else
          format('\\x%02x', cp).tap { |t| control << t }
        end
      end

      Result.new(text: clean, warnings: warnings_for(backspace, control, bidi, zero_width, mixed_script_tokens(text)))
    end

    # Tokens (whitespace-delimited runs) that combine letters from two or
    # more of {CONFUSABLE_SCRIPTS} — the homoglyph-spoof signature.
    #
    # @param text [String]
    # @return [Array<String>] distinct offending tokens, first-seen order
    def self.mixed_script_tokens(text)
      text.split(/\s+/).reject(&:empty?).select do |token|
        CONFUSABLE_SCRIPTS.count { |_name, re| token.match?(re) } >= 2
      end.uniq
    end

    # Assemble one {Warning} per non-empty category, in a stable order
    # (most-deceptive first).
    #
    # @return [Array<Warning>]
    def self.warnings_for(backspace, control, bidi, zero_width, mixed)
      out = []
      if backspace
        out << Warning.new(kind: :backspace, offenders: ['\\x08'],
                           explanation: 'Backspace characters present — the model may be trying to visually erase ' \
                                        'part of the text after you have read it.')
      end
      unless bidi.empty?
        out << Warning.new(kind: :bidi, offenders: bidi.uniq,
                           explanation: "Bidirectional-override characters present (#{bidi.uniq.join(' ')}) — these " \
                                        'can reorder how text is displayed so it reads differently than it runs.')
      end
      unless zero_width.empty?
        out << Warning.new(kind: :zero_width, offenders: zero_width.uniq,
                           explanation: "Zero-width / invisible characters present (#{zero_width.uniq.join(' ')}) — " \
                                        'the text may contain characters you cannot see.')
      end
      unless control.empty?
        out << Warning.new(kind: :control_bytes, offenders: control.uniq,
                           explanation: "Non-printable control bytes present (#{control.uniq.join(' ')}) — in a " \
                                        'terminal these can move the cursor, change colors, or hide output.')
      end
      unless mixed.empty?
        out << Warning.new(kind: :mixed_script, offenders: mixed,
                           explanation: "Mixed-script tokens present (#{mixed.join(', ')}) — letters from different " \
                                        "alphabets are combined within one word, a classic homoglyph spoof (e.g. " \
                                        "Cyrillic 'а' standing in for Latin 'a').")
      end
      out
    end
    private_class_method :warnings_for
  end
end
