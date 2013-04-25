module Annotator

  class Annotation
    MATCH_TYPES = {
      type_preferred_name: "PREF",
      type_synonym: "SYN"
    }
    attr_reader :annotations, :hierarchy, :cls

    def initialize(class_id,ontology)
      # a list of [from, to, machType
      @cls = LinkedData::Models::Class.read_only(RDF::IRI.new(class_id),{})
      @cls.submissionAcronym = ontology
      @hierarchy = []
      @annotations = []
    end

    def add_annotation(from, to, matchType) 
      raise ArgumentError, "Invalid annotation type: #{matchType}" unless MATCH_TYPES.values.include?(matchType)
      @annotations << { from: from, to: to, matchType: matchType }
    end

    def add_parent(parent, distance)
      @hierarchy.each do |x|
        return if x[:cls].resource_id.value == parent
      end
      parent_class = LinkedData::Models::Class.read_only(RDF::IRI.new(parent),{})
      parent_class.submissionAcronym = @cls.submissionAcronym
      @hierarchy << { :cls => parent_class, distance: distance}
    end

  end
end
