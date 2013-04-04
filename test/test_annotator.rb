require_relative 'test_case'

class TestAnnotator < TestCase

  def setup

  end

  def teardown

  end

  def test_create_term_cache
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.create_term_cache
  end

  def test_generate_dictionary_file
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.generate_dictionary_file
  end
end
