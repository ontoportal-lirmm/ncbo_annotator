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
      #assert redis.hexists(prefixedId, resourceId)
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
    direct = annotations[Annotator::Models::NcboAnnotator::DIRECT_ANNOTATIONS_LABEL]
    assert size >= direct.length
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
