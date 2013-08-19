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
    @settings.mgrep_dictionary_file ||= "./test/tmp/dictionary.txt"
    @settings.mgrep_host            ||= "localhost"
    @settings.mgrep_port            ||= 55555
    @settings.stop_words_default_file ||= "./test/data/default_stop_words.txt"

    @settings.stop_words_default_list = Set.new
    File.open(@settings.stop_words_default_file, "r").each_line do |line|
        @settings.stop_words_default_list << line.strip().upcase()
    end
    @settings.stop_words_default_list.freeze
  end

end
