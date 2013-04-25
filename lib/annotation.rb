module Annotator

  class Annotation
    MATCH_TYPES = {
      type_preferred_name: "PREF",
      type_synonym: "SYN"
    }
    attr_reader :class, :annotations, :hierarchy, :class

    def initialize(class_id,ontology)
      # a list of [from, to, machType
      @class = LinkedData::Models::Class.read_only(RDF::IRI.new(class_id),{})
      @class.submissionAcronym = ontology
      @hierarchy = []
      @annotations = []
    end

    def add_annotation(from, to, matchType) 
      raise ArgumentError, "Invalid annotation type: #{matchType}" unless MATCH_TYPES.values.include?(matchType)
      @annotations << { from: from, to: to, matchType: matchType }
    end

    def add_parent(parent, distance)
      @hierarchy.each do |x|
        return if x[:class].resource_id.value == parent
      end
      parent_class = LinkedData::Models::Class.read_only(RDF::IRI.new(parent),{})
      parent_class.submissionAcronym = @class.submissionAcronym
      @hierarchy << { :class => parent_class, distance: distance}
    end

  end
end
