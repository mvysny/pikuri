# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Reranker
      # A single rerank result: the position of the document in
      # the input array + the cross-encoder's relevance score
      # for it. Returned in descending +score+ order from any
      # reranker's +#rerank+ method.
      #
      # == Fields
      #
      # * +index+ — +Integer+, the position in the original
      #   +documents+ array passed to +#rerank+. Callers use
      #   this to look up the document text + metadata they
      #   already hold.
      # * +score+ — +Float+, the model's relevance score. Range
      #   is model-dependent: Cohere returns +[0.0, 1.0]+ via
      #   a logistic head; raw cross-encoder logits can range
      #   further. Treat the absolute values as opaque — use
      #   them for ordering, not for thresholding (a "0.5
      #   cutoff" rule means different things to different
      #   models).
      #
      # == Why a Data.define
      #
      # Same convention as {Backend::Result}. A tuple +[index,
      # score]+ or a +{index:, score:}+ Hash works at runtime,
      # but +hit.index+ / +hit.score+ reads cleaner at call
      # sites and value-equality is occasionally useful in
      # specs.
      Hit = Data.define(:index, :score)
    end
  end
end
