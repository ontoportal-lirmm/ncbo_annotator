require 'goo'
require 'ostruct'

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
  end

end
