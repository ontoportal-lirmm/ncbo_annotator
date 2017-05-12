require 'goo'
require 'ostruct'
require 'set'

module Annotator
  extend self
  attr_reader :settings

  @settings = OpenStruct.new
  @settings_run = false

  def config(&block)
    return if @settings_run
    @settings_run = true

    yield @settings if block_given?

    # Set defaults
    @settings.mgrep_dictionary_file      ||= "./test/tmp/dictionary.txt"
    @settings.mgrep_host                 ||= "localhost"
    @settings.mgrep_port                 ||= 55555
    @settings.mgrep_alt_host             ||= @settings.mgrep_host
    @settings.mgrep_alt_port             ||= @settings.mgrep_port
    @settings.mgrep_dictionary_file      ||= "./test/tmp/dictionary.txt"
    @settings.mgrep_host                 ||= "localhost"
    @settings.mgrep_port                 ||= 55555
    @settings.mgrep_alt_host             ||= @settings.mgrep_host
    @settings.mgrep_alt_port             ||= @settings.mgrep_port
    @settings.annotator_redis_host       ||= "localhost"
    @settings.annotator_redis_port       ||= 6379
    @settings.enable_recognizer_param    ||= false
    @settings.supported_recognizers      ||= [:mgrep] # :mgrep, :mallet
    puts "(AN) >> Using ANN Redis instance at "+
      "#{@settings.annotator_redis_host}:#{@settings.annotator_redis_port}"

    # Default config for Lemmatization
    @settings.lemmatizer_jar             ||= "/srv/ncbo/Lemmatizer/"
    @settings.mgrep_lem_dictionary_file  ||= "/srv/mgrep/dictionary/dictionary-lem.txt"
    @settings.mgrep_lem_host             ||= "localhost"
    @settings.mgrep_lem_port             ||= 55557

    # Stop words
    stop_words_path = File.expand_path("../../../test/data/default_stop_words.txt", __FILE__)
    @settings.stop_words_default_file    ||= stop_words_path

    @settings.stop_words_default_list = Set.new
    File.open(@settings.stop_words_default_file, "r").each_line do |line|
        @settings.stop_words_default_list << line.strip().upcase()
    end
    @settings.stop_words_default_list.freeze

    @settings.annotator_redis_prefix     ||= "c1:"
    @settings.annotator_redis_alt_prefix ||= "c2:"
  end

end
