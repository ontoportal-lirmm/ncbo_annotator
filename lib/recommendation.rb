module Recommender

  class Recommendation

    include LinkedData::Hypermedia::Resource

    attr_accessor :ontology, :score, :numTermsMatched, :numTermsTotal, :annotatedClasses

    embed :annotatedClasses
    
    def initialize
      @score = 0
      @numTermsMatched = 0
      @annotatedClasses = []
    end

    def increment_score(annotation)
      annotation.annotations.each do |occ|
        if occ[:matchType] == "PREF"
          @score += 10
        elsif occ[:matchType] == "SYN"
          @score += 5
        end
      end
      @score += annotation.hierarchy.length * 2
    end

  end

end