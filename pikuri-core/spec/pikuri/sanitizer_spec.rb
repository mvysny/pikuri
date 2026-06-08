# frozen_string_literal: true

RSpec.describe Pikuri::Sanitizer do
  def sanitize(text)
    described_class.sanitize(text)
  end

  def kinds(text)
    sanitize(text).warnings.map(&:kind)
  end

  describe '.sanitize neutralization' do
    it 'leaves clean ASCII untouched and warns nothing' do
      r = sanitize('plain ascii, nothing funny — even an em dash')
      assert_equal 'plain ascii, nothing funny — even an em dash', r.text
      assert_empty r.warnings
    end

    it 'escapes a carriage return so it cannot overwrite the echoed line' do
      r = sanitize("echo hi\rrm -rf /")
      assert_equal 'echo hi\\x0drm -rf /', r.text
      refute_includes r.text, "\r"
    end

    it 'escapes ESC, the ANSI introducer' do
      assert_equal 'nice\\x1b[2Kdesc', sanitize("nice\e[2Kdesc").text
    end

    it 'escapes DEL and C1 control bytes' do
      assert_equal 'a\\x7fb\\x9cc', sanitize("a\x7fbc").text
    end

    it 'preserves newline (multi-line commands are normal)' do
      r = sanitize("for x in 1 2; do\n  echo $x\ndone")
      assert_equal "for x in 1 2; do\n  echo $x\ndone", r.text
      assert_empty r.warnings
    end

    it 'visualizes tab as \\t rather than collapsing it to a space' do
      r = sanitize("recipe:\n\techo build")
      assert_equal "recipe:\n\\techo build", r.text
      assert_empty r.warnings
    end

    it 'escapes bidi overrides and zero-width characters to \\u{...}' do
      assert_equal 'a\\u{202e}b', sanitize("a‮b").text
      assert_equal 'a\\u{200b}b', sanitize("a​b").text
    end
  end

  describe '.sanitize warnings' do
    it 'reports control bytes with the distinct escaped offenders' do
      w = sanitize("a\rb\rc\x00").warnings.find { |x| x.kind == :control_bytes }
      assert_equal ['\\x0d', '\\x00'], w.offenders
    end

    it 'calls out backspace as its own warning, separate from control_bytes' do
      ks = kinds("erase this\b\b\b")
      assert_includes ks, :backspace
      refute_includes ks, :control_bytes
    end

    it 'warns on bidi overrides' do
      assert_includes kinds("legit‮reversed"), :bidi
    end

    it 'warns on zero-width characters' do
      assert_includes kinds("hid​den"), :zero_width
    end

    it 'orders warnings most-deceptive first: backspace, bidi, zero_width, control' do
      assert_equal %i[backspace bidi zero_width control_bytes],
                   kinds("x\by‮z​w\r")
    end

    it 'each warning carries a non-empty plain-text explanation' do
      sanitize("x‮​\r\b").warnings.each do |w|
        assert_kind_of String, w.explanation
        refute_empty w.explanation
      end
    end
  end

  describe '.sanitize mixed-script detection' do
    it 'flags a token mixing Latin and Cyrillic (homoglyph spoof)' do
      w = sanitize('visit https://Pаypal.com now').warnings.find { |x| x.kind == :mixed_script }
      refute_nil w
      assert_equal ['https://Pаypal.com'], w.offenders
    end

    it 'does not flag a single-script token (legit foreign text)' do
      assert_empty kinds('café Москва ελληνικά naïve')
    end

    it 'does not flag scripts separated across different tokens' do
      assert_empty kinds("# Москва is the capital\nputs greeting")
    end
  end

  describe '.mixed_script_tokens' do
    it 'returns distinct offending tokens in first-seen order' do
      assert_equal %w[Pаypal Gооgle],
                   described_class.mixed_script_tokens('Pаypal Gооgle Pаypal café')
    end

    it 'returns [] for clean text' do
      assert_equal [], described_class.mixed_script_tokens('all latin words here')
    end
  end

  describe Pikuri::Sanitizer::Result do
    it 'carries text and warnings' do
      r = described_class.new(text: 'x', warnings: [])
      assert_equal 'x', r.text
      assert_equal [], r.warnings
    end
  end

  describe Pikuri::Sanitizer::Warning do
    it 'carries kind, offenders and explanation' do
      w = described_class.new(kind: :backspace, offenders: ['\\x08'], explanation: 'nope')
      assert_equal :backspace, w.kind
      assert_equal ['\\x08'], w.offenders
      assert_equal 'nope', w.explanation
    end
  end
end
