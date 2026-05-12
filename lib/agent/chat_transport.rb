# frozen_string_literal: true

class Agent
  # The trio of arguments that has to travel together to +RubyLLM.chat+
  # for model resolution to come out the same on every construction:
  # the model id, the provider hint, and the registry-bypass flag.
  #
  # Bundling them is structural protection against a recurring bug
  # class — every forwarding site (the synthesizer rescue in
  # {Agent#run_loop}, {Tool::SubAgent.build} spawning a sub-agent)
  # used to pass the three individually, and dropping one routed the
  # spawned chat to a different server or raised
  # +RubyLLM::ModelNotFoundError+ on the unknown model id. With a
  # single value object the call site can't silently miss a field.
  #
  # Pure data carrier: no +RubyLLM+ references here, so the seam stays
  # in {Agent}, +bin/pikuri+, and {Tool}.
  #
  # @!attribute [r] model
  #   @return [String, nil] LLM identifier; +nil+ defers to
  #     +RubyLLM.config.default_model+ at {Agent} construction time
  # @!attribute [r] provider
  #   @return [Symbol, nil] forwarded to +RubyLLM.chat+. Required
  #     together with +assume_model_exists+ when pointing at a local
  #     OpenAI-compatible server (llama.cpp, gpustack, ...) whose model
  #     ids are not in ruby_llm's bundled registry.
  # @!attribute [r] assume_model_exists
  #   @return [Boolean] forwarded to +RubyLLM.chat+; +true+ skips
  #     ruby_llm's registry lookup and trusts the supplied model id.
  #     Requires +provider+.
  class ChatTransport < Data.define(:model, :provider, :assume_model_exists)
    # @param model [String, nil]
    # @param provider [Symbol, nil]
    # @param assume_model_exists [Boolean]
    def initialize(model:, provider: nil, assume_model_exists: false)
      super
    end
  end
end
