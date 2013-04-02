require_relative 'test_case'

class TestAnnotator < TestCase

  def setup

  end

  def teardown

  end

  def test_create_dict
    annotator = Annotator::Models::NcboAnnotator.new
    annotator.create_dictionary
  end
end
