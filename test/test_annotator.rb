require_relative 'test_case'



require_relative "../lib/ncbo_annotator/recognizers/mallet"


require 'json'
require 'redis'

class TestAnnotator < TestCase

  def self.before_suite
    @@redis = Annotator::Models::NcboAnnotator.new.redis
    db_size = @@redis.dbsize
    if db_size > 5000
      puts "   This test cannot be run. You are probably pointing to the wrong redis backend. "
      return
    end

    mappings = @@redis.keys.select { |x| x["mappings:"] }
    if mappings.length > 0
      @@redis.del(mappings)
    end

    #LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    #@@ontologies = LinkedData::SampleData::Ontology.sample_owl_ontologies
    #annotator = Annotator::Models::NcboAnnotator.new
    #annotator.create_term_cache_from_ontologies(@@ontologies, true)
    #mapping_test_set
  end

  def self.after_suite
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
  end

  def test_all_classes_in_cache
    class_pages = TestAnnotator.all_classes(@@ontologies)
    annotator = Annotator::Models::NcboAnnotator.new
    assert class_pages.length > 100, "No classes in system ???"
    class_pages.each do |cls|
      prefLabel = cls.prefLabel
      resourceId = cls.id.to_s
      prefixedId = annotator.get_prefixed_id_from_value(prefLabel)

      if prefLabel.length > 2
        assert @@redis.exists(prefixedId)
        assert @@redis.hexists(prefixedId, resourceId)
        assert @@redis.hexists(Annotator::Models::NcboAnnotator::DICTHOLDER, prefixedId)
        assert_equal @@redis.hget(Annotator::Models::NcboAnnotator::DICTHOLDER, prefixedId), prefLabel
        assert !@@redis.hget(prefixedId, resourceId).empty?
      else
        assert !@@redis.exists(prefixedId)
      end
    end
  end

  def test_generate_dictionary_file
    ontologies = @@ontologies.dup
    class_pages = TestAnnotator.all_classes(ontologies)
    assert class_pages.length > 100, "No classes in system ???"
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.generate_dictionary_file
    assert File.exists?(Annotator.settings.mgrep_dictionary_file), "The dictionary file did not get created successfully"
    lines = File.readlines(Annotator.settings.mgrep_dictionary_file)

    class_pages.each do |cls|
      prefLabel = cls.prefLabel
      if prefLabel.length > 2
        resourceId = cls.id.to_s
        prefixedId = annotator.get_prefixed_id_from_value(prefLabel)
        index = lines.select{|e| e.strip().split("\t")[1] == prefLabel }
        assert index.length > 0, "The concept: #{resourceId} (#{prefLabel}) was not found in the dictionary file"
      end
    end
    #make sure length term is > 2
    lines.each do |line|
      assert line.strip().split("\t")[1].length > 2
    end
  end




  def test_mallet
    annotator = Annotator::Models::Recognizers::Mallet.new

    #annotator.annotate_direct("Depression with cognitive impairment, so called depressive pseudodementia, is commonly mistaken for a neurodegenerative dementia. Using positron emission tomography (PET) derived measures of regional cerebral blood flow (rCBF) a cohort of 33 patients with major depression was studied. Ten patients displayed significant and reversible cognitive impairment. The patterns of rCBF of these patients were compared with a cohort of equally depressed non-cognitively impaired depressed patients. In the depressed cognitively impaired patients a profile of rCBF abnormalities was identified consisting of decreases in the left anterior medial prefrontal cortex and increases in the cerebellar vermis. These changes were additional to those seen in depression alone and are distinct from those described in neurodegenerative dementia. The cognitive impairment seen in a proportion of depressed patients would seem to be associated with dysfunction of neural systems distinct from those implicated in depression alone or the neurodegenerative dementias.")

    annotator.annotate_direct("Schizophrenia subjects demonstrate difficulties on tasks requiring saccadic inhibition, despite normal refixation saccade performance. Saccadic inhibition is ostensibly mediated via prefrontal cortex and associated cortical/subcortical circuitry. The current study tests hypotheses about the neural substrates of normal and abnormal saccadic performance among subjects with schizophrenia.Using functional magnetic resonance imaging, blood oxygenation level-dependent (BOLD) data were recorded while 13 normal and 14 schizophrenia subjects were engaged in refixation and antisaccade tasks.Schizophrenia subjects did not demonstrate the increased prefrontal cortex BOLD contrast during antisaccade performance that was apparent in the normal subjects. Schizophrenia subjects did, however, demonstrate normal BOLD contrast associated with refixation saccade performance in the frontal and supplementary eye fields, and posterior parietal cortex.Results from the current study support hypotheses of dysfunctional prefrontal cortex circuitry among schizophrenia subjects. Furthermore, this abnormality existed despite normal BOLD contrast observed during refixation saccade generation in the schizophrenia group.")


  end


  def test_annotate
    ontologies = @@ontologies.dup
    class_page = TestAnnotator.all_classes(ontologies)
    class_page = class_page[0..150]
    text = []
    size = 0

    class_page.each do |cls|
      prefLabel = cls.prefLabel
      text << "#{prefLabel}"
      if prefLabel.length > 2
        size += 1
      end
    end
    text = text.join ", "

    texts = [text, text.upcase, text.downcase]
    texts.each do |text|
      annotator = Annotator::Models::NcboAnnotator.new
      annotations = annotator.annotate(text, [], [], true, 0)
      direct = annotations

      assert direct.length >= size && direct.length > 0
      found = 0
      class_page.each do |cls|
        if cls.prefLabel.length > 2
          #TODO: This assertion may fail if the dictionary file on mgrep server does not contain the terms from the test ontologies
          assert (direct.select { |x| x.annotatedClass.id.to_s == cls.id.to_s }).length > 0
          found += 1
        end
      end
      assert found >= size
    end

    # test for a specific class annotation
    term_text = "Data Storage"
    text = "#{term_text} is needed"
    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text)

    assert annotations.length == 1
    assert annotations.first.annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Storage"
    assert annotations.first.annotations.length == 1
    assert annotations.first.annotations.first[:from] == 1
    assert annotations.first.annotations.first[:to] == term_text.length
    assert text[annotations.first.annotations.first[:from] - 1, annotations.first.annotations.first[:to]] == term_text

    # check for a non-existent ontology
    non_existent_ont = ["DOESNOTEXIST"]
    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text, non_existent_ont)
    assert_empty(annotations)

    # check for a specific term
    term_text = "Outcomes research"
    text = "When #{term_text} is obtained properly, a new research can begin."
    annotations = annotator.annotate(text)

    # test for specific ontologies

  end

  def test_annotate_minsize_term
    ontologies = @@ontologies.dup
    class_page = TestAnnotator.all_classes(ontologies)
    class_page = class_page[0..150]
    text = []
    size = 0

    class_page.each do |cls|
      prefLabel = cls.prefLabel
      text << "#{prefLabel}"
      if prefLabel.length > 2
        size += 1
      end
    end
    text = text.join ", "

    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text, [], [], true, 0,false)
    direct = annotations

    assert direct.length >= size && direct.length > 0
    found = 0
    filter_out_next = []
    must_be_next = []
    class_page.each do |cls|
      if cls.prefLabel.length > 2
        #TODO: This assertion may fail if the dictionary file on mgrep server does not contain the terms from the test ontologies
        assert (direct.select { |x| x.annotatedClass.id.to_s == cls.id.to_s }).length > 0
        found += 1
        if cls.prefLabel.length < 10
          filter_out_next << cls
        else
          must_be_next << cls
        end
      end
    end
    assert found >= size

    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text, [], [], true, 0,false,min_term_size=10)
    direct = annotations
    filter_out_next.each do |cls|
      assert (direct.select { |x| x.annotatedClass.id.to_s == cls.id.to_s }).length == 0
    end
    must_be_next.each do |cls|
      assert (direct.select { |x| x.annotatedClass.id.to_s == cls.id.to_s }).length > 0
    end
    assert must_be_next.length > 0 && filter_out_next.length > 0
  end


  def test_annotate_stop_words
    ontologies = @@ontologies.dup
    text = "Aggregate Human Data, Resource deletion, chromosomal chromosomal mutation"
    annotator = Annotator::Models::NcboAnnotator.new
    annotations = annotator.annotate(text)
    not_show = ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
                "http://purl.obolibrary.org/obo/MCBCC_0000296#Deletion"]

    not_show.each do |cls|
      assert (annotations.select { |x| x.annotatedClass.id.to_s == cls }).length > 0
    end

    #annotation should not show up
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.stop_words= ["resource", "deletion"]
    annotations = annotator.annotate(text)
    not_show.each do |cls|
      assert (annotations.select { |x| x.annotatedClass.id.to_s == cls }).length == 0
    end

    #empty array must annotate all
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.stop_words= []
    annotations = annotator.annotate(text)
    not_show.each do |cls|
      assert (annotations.select { |x| x.annotatedClass.id.to_s == cls }).length > 0
    end
  end

  def test_annotate_hierarchy
    ontologies = @@ontologies.dup
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

    assert annotations[3].annotatedClass.id.to_s == "http://purl.obolibrary.org/obo/MCBCC_0000296#Deletion"
    hhh = annotations[3].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh = ["http://purl.obolibrary.org/obo/MCBCC_0000287#GeneticVariation",
     "http://purl.obolibrary.org/obo/MCBCC_0000295#GeneMutation"]

    assert annotations[4].annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
    hhh = annotations[4].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
 "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Information_Resource"]

    assert annotations[5].annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource"
    hhh = annotations[5].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == [] #root

    assert annotations[6].annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Federal_Funding_Resource"
    hhh = annotations[6].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
 "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Funding_Resource"]

    assert annotations[7].annotatedClass.id.to_s == "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Funding_Resource"
    hhh = annotations[7].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource" ]

    assert annotations[8].annotatedClass.id.to_s == "http://purl.obolibrary.org/obo/MCBCC_0000275#ReceptorAntagonists"
    hhh = annotations[8].hierarchy.sort {|x| x.distance }.map { |x| x.annotatedClass.id.to_s }
    assert hhh == ["http://purl.obolibrary.org/obo/MCBCC_0000256#ChemicalsAndDrugs"]

  end

  def self.mapping_test_set
    raise Exception, "Too many mappings in KB for testing" if LinkedData::Models::Mapping.all.count > 1000
    Goo.sparql_data_client.delete_graph(LinkedData::Models::Mapping.type_uri)
    Goo.sparql_data_client.delete_graph(LinkedData::Models::TermMapping.type_uri)
    Goo.sparql_data_client.delete_graph(LinkedData::Models::MappingProcess.type_uri)
    terms_a = ["http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Resource",
               "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data",
               "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource",
               "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"]
    onts_a = ["BROTEST-0","BROTEST-0","BROTEST-0","BROTEST-0"]
    terms_b = ["http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#La_mastication_de_produit",
               "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Article",
               "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Maux_de_rein",
               "http://purl.obolibrary.org/obo/MCBCC_0000344#PapillaryInvasiveDuctalTumor"]
    onts_b = ["ONTOMATEST-0","ONTOMATEST-0","ONTOMATEST-0", "MCCLTEST-0"]

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
        assert ann.mappings.first[:annotatedClass].id.to_s ==
            "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Article"
        assert ann.mappings.first[:annotatedClass].submission.ontology.id.to_s ==
          "http://data.bioontology.org/ontologies/ONTOMATEST-0"
      elsif ann.annotatedClass.id.to_s ==
          "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
        step_in_here += 1
        assert ann.mappings.length == 2
        ann.mappings.each do |map|
          if map[:annotatedClass].id.to_s =="http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Maux_de_rein"
            assert map[:annotatedClass].submission.ontology.id.to_s["ONTOMATEST-0"]
          elsif map[:annotatedClass].id.to_s == "http://purl.obolibrary.org/obo/MCBCC_0000344#PapillaryInvasiveDuctalTumor"
            assert map[:annotatedClass].submission.ontology.id.to_s["MCCLTEST-0"]
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
    ontologies = ["http://data.bioontology.org/ontologies/ONTOMATEST-0",
                 "http://data.bioontology.org/ontologies/BROTEST-0"]
    annotations = annotator.annotate(text,ontologies, [], false, expand_hierachy_levels=0,expand_with_mappings=true)
    step_in_here = 0
    annotations.each do |ann|
      if ann.annotatedClass.id.to_s ==
          "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Aggregate_Human_Data"
        step_in_here += 1
        assert ann.mappings.length == 1
        assert ann.mappings.first[:annotatedClass].id.to_s ==
          "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Article"
        assert ann.mappings.first[:annotatedClass].submission.ontology.id.to_s ==
          "http://data.bioontology.org/ontologies/ONTOMATEST-0"
      elsif ann.annotatedClass.id.to_s ==
              "http://bioontology.org/ontologies/BiomedicalResourceOntology.owl#Data_Resource"
        step_in_here += 1
        assert ann.mappings.length == 1
        ann.mappings.each do |map|
          if map[:annotatedClass].id.to_s ==
                "http://www.semanticweb.org/associatedmedicine/lavima/2011/10/Ontology1.owl#Maux_de_rein"
            assert map[:annotatedClass].submission.ontology.id.to_s["ONTOMATEST-0"]
          else
            assert 1==0
          end
        end
      end
    end
    assert step_in_here == 2
  end

  def self.all_classes(ontologies)
    classes = []
    ontologies.each do |ontology|
      last = ontology.latest_submission
      page = 1
      size = 500
      paging = LinkedData::Models::Class.in(last)
                            .include(:prefLabel, :synonym, :definition)
                            .page(page, size)
      begin
        page_classes = paging.page(page,size).all
        page = page_classes.next? ? page + 1 : nil
        classes += page_classes
      end while !page.nil?
    end
    return classes
  end

end
