module Annotator
  class Annotation
    MATCH_TYPES = {
      type_preferred_name: "PREF",
      type_synonym: "SYN"
    }

    def initialize(from, to, matchType, annotatedClass)
      raise ArgumentError, "Invalid annotation type: #{matchType}" unless MATCH_TYPES.values.include?(matchType)

      @from = from
      @to = to
      @matchType = matchType
      @annotatedClass = annotatedClass
    end

    attr_reader :from, :to, :matchType, :annotatedClass
  end
end