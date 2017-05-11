require 'open3'
require 'logger'
require 'addressable/uri'
require_relative '../rabbitmq/recognizer_client'

module Annotator
  module Models
    module Recognizers

      class Ehealth2017 < Annotator::Models::NcboAnnotator


        def initialize
          super()
          @client = RecognizerClient.new(Annotator.settings.rabbitmq_host, Annotator.settings.rabbitmq_port)
          @logger = Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)
        end


        def annotate_direct(text, options={})
          uri = Addressable::URI.new
          uri.query_values = options
          params = uri.query

          stdout = @client.call(text)
          labels = stdout.split(" ")
          @logger.info(labels)
          allAnnotations = {}

          #labels.each do |label|
          #  category, sub_category = parse_label(label)
          #  hit = search_query(sub_category) unless (sub_category.nil?)

          #  unless hit.nil?
          #    resource_id = hit["resource_id"]
          #    allAnnotations[resource_id] = Annotation.new(resource_id, COGPO_RESOURCE_ID)
          #  end
          #end

          return allAnnotations
        end

        def search_query(label)
          query = "\"#{solr_escape(label)}\""
          params = Hash.new
          params["defType"] = "edismax"
          params["stopwords"] = "true"
          params["lowercaseOperators"] = "true"
          params["qf"] = "prefLabelExact"
          params["fq"] = "submissionAcronym:\"#{COGPO_ACRONYM}\""
          params["fl"] = "resource_id"
          params["q"] = query
          resp = LinkedData::Models::Class.search(query, params)
          total_found = resp["response"]["numFound"]
          hit = (total_found > 0) ? resp["response"]["docs"][0] : nil

          return hit
        end

        def solr_escape(text)
          RSolr.solr_escape(text).gsub(/\s+/,"\\ ")
        end

        def parse_label(full_label)
          category = CATEGORIES.select {|cat, lbl| full_label.start_with?(cat)}
          main_cat = nil
          sub_cat = nil

          unless category.empty?
            main_cat = category.values[0]
            sub_cat_key = full_label.gsub(category.keys[0], "")
            sub_cat = sub_cat_key.split(/(?=[A-Z])/).join(" ")
          end

          return main_cat, sub_cat
        end

      end
    end
  end
end
