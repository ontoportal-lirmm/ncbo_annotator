module Annotator
  class HierarchyClass
    include LinkedData::Hypermedia::Resource
    attr_accessor :annotatedClass, :distance
    embed :annotatedClass
    def initialize(annotatedClass, distance)
      @annotatedClass = annotatedClass; @distance = distance
    end
  end
  
  class Annotation
    include LinkedData::Hypermedia::Resource

    MATCH_TYPES = {
      type_preferred_name: "PREF",
      type_synonym: "SYN"
    }

    attr_reader :annotations, :hierarchy, :annotatedClass
    
    # Support serializating from ontologies_linked_data and ontologies_api
    embed :annotatedClass, :hierarchy

    def initialize(class_id,ontology)
      # a list of [from, to, machType
      @annotatedClass = LinkedData::Models::Class.read_only(RDF::IRI.new(class_id),{})
      @annotatedClass.submissionAcronym = ontology
      @hierarchy = []
      @annotations = []
    end

    def add_annotation(from, to, matchType) 
      raise ArgumentError, "Invalid annotation type: #{matchType}" unless MATCH_TYPES.values.include?(matchType)
      @annotations << { from: from, to: to, matchType: matchType }
    end

    def add_parent(parent, distance)
      @hierarchy.each do |x|
        return if x.annotatedClass.resource_id.value == parent
      end
      parent_class = LinkedData::Models::Class.read_only(RDF::IRI.new(parent),{})
      parent_class.submissionAcronym = @annotatedClass.submissionAcronym
      @hierarchy << HierarchyClass.new(parent_class, distance)
    end

  end
end
