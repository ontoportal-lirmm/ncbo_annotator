#!/usr/bin/env ruby
# encoding: utf-8

require "bundler/setup"
require "thread"

require_relative '../../../lib/ncbo_annotator/mgrep/mgrep_annotated_text'

module Annotator
  class UnitexRecognizerClient
    attr_reader :reply_queue
    attr_accessor :response, :call_id
    attr_reader :lock, :condition


    def initialize(url)

      @url = url
    end

    def annotate(text, longest_only)
      begin
        text = text.upcase.gsub("\n", " ")
      rescue ArgumentError => e
        # NCBO-1230 - Annotation failure after repeated calls
        text = text.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
        text = text.upcase.gsub("\n", " ")
      end

      if text.strip.length == 0
        return Annotator::Mgrep::AnnotatedText(text, [])
      end

      lo = "false"
      if longest_only
        lo="true"
      end

      res = RestClient.get @url, {params: {:text => text, :longest_only => lo}}
      annotations = []
      for line in res.body.split("\n") do
        fields = line.split("\t")
        if fields.length > 1
          annotations << fields
        end
      end
      Annotator::Mgrep::AnnotatedText.new(text, annotations)
    end

  end
end
