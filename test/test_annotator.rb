require_relative 'test_case'
require 'json'
require 'redis'

class TestAnnotator < TestCase

  def self.before_suite
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    @@ontologies = LinkedData::SampleData::Ontology.sample_owl_ontologies
    mapping_test_set
  end
  
  def self.after_suite
    return
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
  end

  def test_create_term_cache

    redis = Redis.new(:host => LinkedData.settings.redis_host, :port => LinkedData.settings.redis_port)

    db_size = redis.dbsize
    if db_size > 2000
      puts "   This test cannot be run. You are probably pointing to the wrong redis backend. "
      return
    end

    ontologies = @@ontologies.dup
    class_page = get_classes(ontologies)
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.create_term_cache_from_ontologies(ontologies)

    assert redis.exists(Annotator::Models::NcboAnnotator::DICTHOLDER), "The dictionary structure did not get created successfully"

    class_page.each do |cls|
      prefLabel = cls.prefLabel
      resourceId = cls.id.to_s
      prefixedId = annotator.get_prefixed_id_from_value(prefLabel)
      assert redis.exists(prefixedId)
      assert redis.hexists(prefixedId, resourceId)
      assert redis.hexists(Annotator::Models::NcboAnnotator::DICTHOLDER, prefixedId)
      assert_equal redis.hget(Annotator::Models::NcboAnnotator::DICTHOLDER, prefixedId), prefLabel
      assert !redis.hget(prefixedId, resourceId).empty?
    end
  end

  def test_generate_dictionary_file
    ontologies = @@ontologies.dup
    class_page = get_classes(ontologies)
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.generate_dictionary_file
    assert File.exists?(Annotator.settings.mgrep_dictionary_file), "The dictionary file did not get created successfully"
    lines = File.readlines(Annotator.settings.mgrep_dictionary_file)

    class_page.each do |cls|
      prefLabel = cls.prefLabel
      resourceId = cls.id.to_s
      prefixedId = annotator.get_prefixed_id_from_value(prefLabel)
      index = lines.index{|e| e =~ /#{prefLabel}/ }
      refute_nil index, "The concept: #{resourceId} (#{prefLabel}) was not found in the dictionary file"
    end
  end

  def test_annotate
    ontologies = @@ontologies.dup
    class_page = get_classes(ontologies)
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.generate_dictionary_file
    assert File.exists?(Annotator.settings.mgrep_dictionary_file), "The dictionary file did not get created successfully"
    text = []
    size = 0

    class_page.each do |cls|
      prefLabel = cls.prefLabel
      text << "#{prefLabel}"
      size += 1
    end
    text = text.join ", "
    annotations = annotator.annotate(text, [], [], true, 0)
    direct = annotations
    assert ((size <= direct.length) && direct.length > 0)
  end

  def test_annotate_hierarchy
    ontologies = @@ontologies.dup
    class_page = get_classes(ontologies)
    text = "Aggregate Human Data Aggregate Human Data"
    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text)
    assert annotations.length == 1
    assert annotations.first.annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data"
    assert annotations.first.annotatedClass.submission.ontology.acronym == "BROTEST-0"
    assert annotations.first.annotations.length == 2
    assert annotations.first.annotations.first[:from] = 1
    assert annotations.first.annotations.first[:to] = 1+("Aggregate Human Data".length)
    assert annotations.first.annotations[1][:from] = 2 + ("Aggregate Human Data".length)
    assert text[annotations.first.annotations.first[:from]-1,annotations.first.annotations.first[:to]-1] == "Aggregate Human Data"
    assert annotations.first.annotations[1][:to] == (1 + ("Aggregate Human Data".length)) + ("Aggregate Human Data".length)
    assert text[annotations.first.annotations[1][:from]-1,annotations.first.annotations[1][:to]-1] == "Aggregate Human Data"

    annotations = annotator.annotate(text, ontologies=[], semantic_types=[], false, expand_hierachy_levels=1)
    assert annotations.length == 1
    assert annotations.first.annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data"
    assert annotations.first.annotatedClass.submission.ontology.acronym == "BROTEST-0"
    assert annotations.first.annotations.length == 2
    assert annotations.first.annotations.first[:from] = 1
    assert annotations.first.annotations.first[:to] = 1+("Aggregate Human Data".length)

    assert annotations.first.hierarchy.length == 1
    assert annotations.first.hierarchy.first.annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Clinical_Care_Data"
    assert annotations.first.hierarchy.first.distance == 1

    annotations = annotator.annotate(text, ontologies=[], semantic_types=[], false, expand_hierachy_levels=3)
    assert annotations.first.hierarchy.length == 3
    assert annotations.first.hierarchy.first.annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Clinical_Care_Data"
    assert annotations.first.hierarchy.first.distance == 1
    assert annotations.first.hierarchy[1].annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
    assert annotations.first.hierarchy[1].distance == 2
    assert annotations.first.hierarchy[2].annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Information_Resource"
    assert annotations.first.hierarchy[2].distance == 3
  end

  def test_annotate_hierachy_terms_multiple
    ontologies = @@ontologies.dup
    text = "Aggregate Human Data chromosomal mutation Aggregate Human Data chromosomal deletion Aggregate Human Data Resource Federal Funding Resource receptor antagonists chromosomal mutation"
    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text,[], [], false, expand_hierachy_levels=5)

    assert annotations[0].annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data"
    assert annotations[0].annotations.length == 3
    assert annotations[0].hierarchy.length == 4
    hhh = annotations[0].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == [
      "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
      "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Information_Resource",
      "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Clinical_Care_Data",
      "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
    ]

    assert annotations[1].annotatedClass.id.to_s == "http://purl.obolibrary.org/obo/MCBCC_0000288#ChromosomalMutation"
    assert annotations[1].annotations.length == 2
    hhh = annotations[1].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    hhh == ["http://purl.obolibrary.org/obo/MCBCC_0000287#GeneticVariation"]

    assert annotations[2].annotatedClass.id.to_s == "http://purl.obolibrary.org/obo/MCBCC_0000289#ChromosomalDeletion"
    assert annotations[2].annotations.length == 1
    hhh = annotations[2].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == ["http://purl.obolibrary.org/obo/MCBCC_0000287#GeneticVariation",
            "http://purl.obolibrary.org/obo/MCBCC_0000288#ChromosomalMutation"]

    assert annotations[3].annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
    hhh = annotations[3].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
 "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Information_Resource"]

    assert annotations[4].annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Federal_Funding_Resource"
    hhh = annotations[4].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
 "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Funding_Resource"]

    assert annotations[5].annotatedClass.id.to_s == "http://purl.obolibrary.org/obo/MCBCC_0000275#ReceptorAntagonists"
    hhh = annotations[5].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == ["http://purl.obolibrary.org/obo/MCBCC_0000256#ChemicalsAndDrugs"]

  end

  def self.mapping_test_set
    terms_a = ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
               "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data",
               "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource",
               "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"]
    onts_a = ["BROTEST-0","BROTEST-0","BROTEST-0","BROTEST-0"]
    terms_b = ["http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#La_mastication_de_produit",
               "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Article",
               "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Maux_de_rein",
               "http://purl.obolibrary.org/obo/MCBCC_0000344#PapillaryInvasiveDuctalTumor"]
    onts_b = ["OntoMATEST-0","OntoMATEST-0","OntoMATEST-0", "MCCLTEST-0"]

    user_creator = LinkedData::Models::User.where.include(:username).page(1,100).first
    if user_creator.nil?
      u = LinkedData::Models::User.new(username: "tim", email: "tim@example.org", password: "password")
      u.save
      user_creator = LinkedData::Models::User.where.include(:username).page(1,100).first
    end
    process = LinkedData::Models::MappingProcess.new(:creator => user_creator, :name => "TEST Mapping Annotator")
    process.date = DateTime.now 
    process.relation = RDF::URI.new("http://bogus.relation.com/predicate")
    process.save

    4.times do |i|
      term_mappings = []
      term_mappings << LinkedData::Mappings.create_term_mapping([RDF::URI.new(terms_a[i])], onts_a[i])
      term_mappings << LinkedData::Mappings.create_term_mapping([RDF::URI.new(terms_b[i])], onts_b[i])
      mapping_id = LinkedData::Mappings.create_mapping(term_mappings)
      LinkedData::Mappings.connect_mapping_process(mapping_id, process)
    end
  end

  def test_annotate_with_mappings
    text = "Aggregate Human Data chromosomal mutation Aggregate Human Data chromosomal deletion Aggregate Human Data Resource Federal Funding Resource receptor antagonists chromosomal mutation"
    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text,[], [], false, expand_hierachy_levels=0,expand_with_mappings=true)
    step_in_here = 0
    annotations.each do |ann|
      if ann.annotatedClass.id.to_s == 
          "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data"
        step_in_here += 1
        assert ann.mappings.length == 1
        assert ann.mappings.first.id.to_s == 
            "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Article"
        assert ann.mappings.first.submission.ontology.id.to_s == 
          "http://data.bioontology.org/ontologies/OntoMATEST-0"
      elsif ann.annotatedClass.id.to_s == 
          "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
        step_in_here += 1
        assert ann.mappings.length == 2
        ann.mappings.each do |map|
          if map.id.to_s =="http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Maux_de_rein"
            assert map.submission.ontology.id.to_s["OntoMATEST-0"]
          elsif map.id.to_s == "http://purl.obolibrary.org/obo/MCBCC_0000344#PapillaryInvasiveDuctalTumor"
            assert map.submission.ontology.id.to_s["MCCLTEST-0"]
          else
            assert 1==0
          end
        end
      else
        ann.mappings.length == 0
      end
    end
    assert step_in_here == 2

    #filtering on ontologies
    ontologies = ["http://data.bioontology.org/ontologies/OntoMATEST-0",
                 "http://data.bioontology.org/ontologies/BROTEST-0"]
    annotations = annotator.annotate(text,ontologies, [], false, expand_hierachy_levels=0,expand_with_mappings=true)
    step_in_here = 0
    annotations.each do |ann|
      if ann.annotatedClass.id.to_s == 
          "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data"
        step_in_here += 1
        assert ann.mappings.length == 1
        assert ann.mappings.first.id.to_s == 
          "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Article"
        assert ann.mappings.first.submission.ontology.id.to_s == 
          "http://data.bioontology.org/ontologies/OntoMATEST-0"
      elsif ann.annotatedClass.id.to_s == 
              "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
        step_in_here += 1
        assert ann.mappings.length == 1
        ann.mappings.each do |map|
          if map.id.to_s ==
                "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Maux_de_rein"
            assert map.submission.ontology.id.to_s["OntoMATEST-0"]
          else
            assert 1==0
          end
        end
      end
    end
    assert step_in_here == 2
  end

  def get_classes(ontologies)
    assert !ontologies.empty?
    ontology = ontologies[0]
    last = ontology.latest_submission
    refute_nil last, "Test submission appears to be nil"
    class_page = LinkedData::Models::Class.in(last)
                                          .include(:prefLabel, :synonym, :definition)
                                          .page(1, 10)
                                          .read_only
                                          .all
    refute_nil class_page, "There appear to be no classes in a test submission"
    return class_page
  end
end
