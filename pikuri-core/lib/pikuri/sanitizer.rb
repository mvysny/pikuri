# frozen_string_literal: true

module Pikuri
  # Renders attacker-controlled text safe to display, and reports *why* it was
  # unsafe.
  #
  # Every string an LLM composes is untrusted (a bash command, a tool
  # observation echoed to the user, a confirmation-prompt description). A model
  # — usually one being prompt-injected — can embed bytes a terminal *acts on*
  # rather than prints: a CR that overwrites the line just read, an ESC that
  # recolors/repositions, a backspace that erases, a bidi override that reorders
  # text so it reads differently than it runs, a zero-width char, or a Cyrillic
  # +а+ posing as Latin +a+. A confirmation prompt is worthless if the bytes the
  # user approves aren't the bytes that execute.
  #
  # {.sanitize} is the one chrome-independent primitive every renderer routes
  # through, returning a {Result}:
  #
  # 1. *Neutralize* — make dangerous bytes visible without changing structure:
  #    control bytes → +\xNN+, bidi/zero-width → +\u{NNNN}+, tab → +\t+;
  #    newlines preserved. *Faithful, not beautifying* — it never collapses
  #    whitespace or rewrites a tab, because the user must see exactly what they
  #    approve (a Makefile's leading tab stays a tab). A web chrome adds
  #    +html_escape+ on top; the HTML layer is the caller's.
  # 2. *Warn* — one {Warning} per category detected (kind + offending tokens +
  #    plain-English explanation). Presentation is the chrome's.
  #
  # == Scope (deliberately closed)
  #
  # Detection is complete on the *invisibility / cursor-control / reordering*
  # classes, each a finite codepoint set: C0/C1 controls, DEL, bidi overrides,
  # zero-width chars. Plus *mixed-script tokens* — one word welding Latin +
  # Cyrillic + Greek, the homoglyph-spoof signature, near-zero false positives
  # (+café+ all-Latin, +Москва+ all-Cyrillic, only +Pаypal+ mixes).
  #
  # Two confusable classes are *out of scope* — detecting them needs Unicode
  # confusables tables and heavy false positives on legitimate multilingual
  # text: *whole-script* homoglyphs (an all-Cyrillic string that looks Latin,
  # no mixing to detect) and *single-symbol* confusables (the Greek +;+ U+037E,
  # full-width forms). "Solid" means complete on the classes above, not
  # exhaustive over Unicode.
  module Sanitizer
    # One reason a piece of text was flagged, for a chrome to render its own way.
    #
    # * +kind+ — a {Symbol}: +:backspace+, +:control_bytes+, +:bidi+,
    #   +:zero_width+, or +:mixed_script+.
    # * +offenders+ — the distinct offending tokens, first-seen order: escaped
    #   forms (+"\\x1b"+, +"\\u{202e}"+) for byte categories, raw tokens
    #   (+"Pаypal"+) for +:mixed_script+.
    # * +explanation+ — a one-line chrome-agnostic summary.
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

    # Codepoints {.sanitize} rewrites: C0 controls including tab (U+0009) but
    # *excluding* newline (U+000A, passes through), C1 + DEL (U+007F–009F), the
    # zero-width set, and the bidi overrides. Newline is the one control a
    # faithful render keeps, so the C0 range splits around it.
    SUSPECT = /[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u200b-\u200d\u202a-\u202e\u2066-\u2069\ufeff]/

    # The three Latin-confusable scripts whose mixing inside one token signals a
    # homoglyph spoof. Punctuation/digits/spaces are +Common+ and match none, so
    # they never count toward the two-script threshold.
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
