require_relative 'test_case'
require 'json'
require 'redis'

class TestAnnotator < TestCase

  def setup

  end

  def teardown

  end

  def test_create_term_cache
    redis = Redis.new
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

    assert File.exists?($MGREP_DICTIONARY_FILE), "The dictionary file did not get created successfully"
    lines = File.readlines($MGREP_DICTIONARY_FILE)

    class_page.each do |cls|
      prefLabel = cls.prefLabel.value
      resourceId = cls.resource_id.value
      prefixedId = annotator.get_prefixed_id_from_value(prefLabel)
      index = lines.index{|e| e =~ /#{prefLabel}/ }
      assert_not_nil index, "The concept: #{resourceId} (#{prefLabel}) was not found in the dictionary file"
    end
  end


  def test_annotate
    annotator = Annotator::Models::NcboAnnotator.new
    text = <<eos
Ginsenosides chemistry, biosynthesis, analysis, and potential health effects in software concept or data." "Ginsenosides are a special group of triterpenoid saponins that can be classified into two groups by the skeleton of their aglycones, namely dammarane- and oleanane-type. Ginsenosides are found nearly exclusively in Panax species (ginseng) and up to now more than 150 naturally occurring ginsenosides have been isolated from roots, leaves/stems, fruits, and/or flower heads of ginseng. The same concept indicates Ginsenosides have been the target of a lot of research as they are believed to be the main active principles behind the claims of ginsengs efficacy. The potential health effects of ginsenosides that are discussed in this chapter include anticarcinogenic, immunomodulatory, anti-inflammatory, antiallergic, antiatherosclerotic, antihypertensive, and antidiabetic effects as well as antistress activity and effects on the central nervous system. Ginsensoides can be metabolized in the stomach (acid hydrolysis) and in the gastrointestinal tract (bacterial hydrolysis) or transformed to other ginsenosides by drying and steaming of ginseng to more bioavailable and bioactive ginsenosides. The metabolization and transformation of intact ginsenosides, which seems to play an important role for their potential health effects, are discussed. Qualitative and quantitative analytical techniques for the analysis of ginsenosides are important in relation to quality control of ginseng products and plant material and for the determination of the effects of processing of plant material as well as for the determination of the metabolism and bioavailability of ginsenosides. Analytical techniques for the analysis of ginsenosides that are described in this chapter are thin-layer chromatography (TLC), high-performance liquid chromatography (HPLC) combined with various detectors, gas chromatography (GC), colorimetry, enzyme immunoassays (EIA), capillary electrophoresis (CE), nuclear magnetic resonance (NMR) spectroscopy, and spectrophotometric methods.
eos
    annotations = annotator.annotate(text)

    puts annotations

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
