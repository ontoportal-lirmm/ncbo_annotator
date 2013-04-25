require_relative 'test_case'
require 'json'
require 'redis'

class TestAnnotator < TestCase

  def setup

  end

  def teardown

  end

  def test_create_term_cache
    redis = Redis.new(:host => LinkedData.settings.redis_host, :port => LinkedData.settings.redis_port)
    ontologies = LinkedData::SampleData::Ontology.sample_owl_ontologies
    class_page = get_classes(ontologies)
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.create_term_cache_from_ontologies(ontologies)

    assert redis.exists(Annotator::Models::NcboAnnotator::DICTHOLDER), "The dictionary structure did not get created successfully"

    class_page.each do |cls|
      prefLabel = cls.prefLabel.value
      resourceId = cls.resource_id.value
      prefixedId = annotator.get_prefixed_id_from_value(prefLabel)
      assert redis.exists(prefixedId)
      assert redis.hexists(prefixedId, resourceId)
      assert redis.hexists(Annotator::Models::NcboAnnotator::DICTHOLDER, prefixedId)
      assert_equal redis.hget(Annotator::Models::NcboAnnotator::DICTHOLDER, prefixedId), prefLabel
      assert !redis.hget(prefixedId, resourceId).empty?
    end
  end

  def test_generate_dictionary_file
    ontologies = LinkedData::SampleData::Ontology.sample_owl_ontologies
    class_page = get_classes(ontologies)
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.generate_dictionary_file
    assert File.exists?(Annotator.settings.mgrep_dictionary_file), "The dictionary file did not get created successfully"
    lines = File.readlines(Annotator.settings.mgrep_dictionary_file)

    class_page.each do |cls|
      prefLabel = cls.prefLabel.value
      resourceId = cls.resource_id.value
      prefixedId = annotator.get_prefixed_id_from_value(prefLabel)
      index = lines.index{|e| e =~ /#{prefLabel}/ }
      assert_not_nil index, "The concept: #{resourceId} (#{prefLabel}) was not found in the dictionary file"
    end
  end

  def test_annotate
    ontologies = LinkedData::SampleData::Ontology.sample_owl_ontologies
    class_page = get_classes(ontologies)
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.generate_dictionary_file
    assert File.exists?(Annotator.settings.mgrep_dictionary_file), "The dictionary file did not get created successfully"
    text = []
    size = 0

    class_page.each do |cls|
      prefLabel = cls.prefLabel.value
      text << "#{prefLabel}"
      size += 1
    end
    text = text.join ", "
    annotations = annotator.annotate(text)
    direct = annotations
    assert ((size <= direct.length) && direct.length > 0)
  end

  def test_annotate_hierarchy
    ontologies = LinkedData::SampleData::Ontology.sample_owl_ontologies
    class_page = get_classes(ontologies)
    text = "Aggregate Human Data Aggregate Human Data"
    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text)
    assert annotations.length == 1
    assert annotations.first.class.resource_id.value == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data"
    assert annotations.first.class.submissionAcronym.first == "http://data.bioontology.org/ontologies/BROTEST"
    assert annotations.first.annotations.length == 2
    assert annotations.first.annotations.first[:from] = 1
    assert annotations.first.annotations.first[:to] = 1+("Aggregate Human Data".length)
    assert annotations.first.annotations[1][:from] = 2 + ("Aggregate Human Data".length)
    assert text[annotations.first.annotations.first[:from]-1,annotations.first.annotations.first[:to]-1] == "Aggregate Human Data"
    assert annotations.first.annotations[1][:to] == (1 + ("Aggregate Human Data".length)) + ("Aggregate Human Data".length)
    assert text[annotations.first.annotations[1][:from]-1,annotations.first.annotations[1][:to]-1] == "Aggregate Human Data"

    annotations = annotator.annotate(text,ontologies=[],expand_hierachy_levels=1)
    assert annotations.length == 1
    assert annotations.first.class.resource_id.value == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data"
    assert annotations.first.class.submissionAcronym.first == "http://data.bioontology.org/ontologies/BROTEST"
    assert annotations.first.annotations.length == 2
    assert annotations.first.annotations.first[:from] = 1
    assert annotations.first.annotations.first[:to] = 1+("Aggregate Human Data".length)

    assert annotations.first.hierarchy.length == 1
    assert annotations.first.hierarchy.first[:class].resource_id.value == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Clinical_Care_Data"
    assert annotations.first.hierarchy.first[:distance] == 1

    annotations = annotator.annotate(text,ontologies=[],expand_hierachy_levels=3)
    assert annotations.first.hierarchy.length == 3
    assert annotations.first.hierarchy.first[:class].resource_id.value == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Clinical_Care_Data"
    assert annotations.first.hierarchy.first[:distance] == 1
    assert annotations.first.hierarchy[1][:class].resource_id.value == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
    assert annotations.first.hierarchy[1][:distance] == 2
    assert annotations.first.hierarchy[2][:class].resource_id.value == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Information_Resource"
    assert annotations.first.hierarchy[2][:distance] == 3
  end

  def test_annotate_hierachy_terms_multiple
    ontologies = LinkedData::SampleData::Ontology.sample_owl_ontologies
    text = "Aggregate Human Data chromosomal mutation Aggregate Human Data chromosomal deletion Aggregate Human Data Resource Federal Funding Resource receptor antagonists chromosomal mutation"
    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text,[],expand_hierachy_levels=5)

    assert annotations[0].annotations.length == 3
    assert annotations[0].class.resource_id.value == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data"
    assert annotations[0].hierarchy.length == 4
    hhh = annotations[0].hierarchy.sort {|x| x[:distance] }.map { |x| x[:class].resource_id.value }
    assert hhh == ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
 "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Information_Resource",
 "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Clinical_Care_Data",
 "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"]

    assert annotations[1].annotations.length == 2
    assert annotations[1].class.resource_id.value == "http://purl.obolibrary.org/obo/MCBCC_0000288#ChromosomalMutation"
    hhh = annotations[1].hierarchy.sort {|x| x[:distance] }.map { |x| x[:class].resource_id.value }
    hhh == ["http://purl.obolibrary.org/obo/MCBCC_0000287#GeneticVariation"]

    assert annotations[2].annotations.length == 1
    assert annotations[2].class.resource_id.value == "http://purl.obolibrary.org/obo/MCBCC_0000289#ChromosomalDeletion"
    hhh = annotations[2].hierarchy.sort {|x| x[:distance] }.map { |x| x[:class].resource_id.value }
    assert hhh == ["http://purl.obolibrary.org/obo/MCBCC_0000287#GeneticVariation",
            "http://purl.obolibrary.org/obo/MCBCC_0000288#ChromosomalMutation"]

    assert annotations[3].class.resource_id.value == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
    hhh = annotations[3].hierarchy.sort {|x| x[:distance] }.map { |x| x[:class].resource_id.value }
    assert hhh == ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
 "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Information_Resource"]

    assert annotations[4].class.resource_id.value == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Federal_Funding_Resource"
    hhh = annotations[4].hierarchy.sort {|x| x[:distance] }.map { |x| x[:class].resource_id.value }
    assert hhh == ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
 "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Funding_Resource"]

    assert annotations[5].class.resource_id.value == "http://purl.obolibrary.org/obo/MCBCC_0000275#ReceptorAntagonists"
    hhh = annotations[5].hierarchy.sort {|x| x[:distance] }.map { |x| x[:class].resource_id.value }
    assert hhh == ["http://purl.obolibrary.org/obo/MCBCC_0000256#ChemicalsAndDrugs"]

  end

  def get_classes(ontologies)
    assert !ontologies.empty?
    ontology = ontologies[0]
    last = ontology.latest_submission
    assert_not_nil last, "Test submission appears to be nil"

    class_page = LinkedData::Models::Class.page submission: last, page: 1, size: 10,
                                                load_attrs: { prefLabel: true, synonym: true, definition: true }
    assert_not_nil class_page, "There appear to be no classes in a test submission"
    return class_page
  end
end
