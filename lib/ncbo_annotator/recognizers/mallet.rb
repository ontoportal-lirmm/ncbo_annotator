require 'open3'
require 'logger'
require "addressable/uri"

module Annotator
  module Models
    module Recognizers

      class Mallet < Annotator::Models::NcboAnnotator

        CATEGORIES = {
          "StimulusModality" => "Stimulus Modality",
          "StimulusType" => "Stimulus Type",
          "ResponseModality" => "Response Modality",
          "ResponseType" => "Response",
          "Instructions" => "Instructions"
        }

        COGPO_ACRONYM = "COGPO"
        COGPO_RESOURCE_ID = "http://data.bioontology.org/ontologies/#{COGPO_ACRONYM}"

        def initialize
          super()
          @mallet_jar_path = $ncbo_annotator_project_bin + "mallet.jar"
          @mallet_deps_jar_path = $ncbo_annotator_project_bin + "mallet_deps.jar"
        end

        def mallet_java_call(text, params="")
          #command_call = "java -cp \"#{$ncbo_annotator_project_bin}.:#{$ncbo_annotator_project_bin}mallet.jar:#{$ncbo_annotator_project_bin}mallet-deps.jar:#{$ncbo_annotator_project_bin}*\" BasicClassifier string \"hello world\""
          params_str = "params \"\""
          params_str = "params \"#{Shellwords.escape(params)}\"" unless params.empty?
          command_call = "java -cp \"#{$ncbo_annotator_project_bin}.:#{$ncbo_annotator_project_bin}*\" BasicClassifier string \"#{Shellwords.escape(text)}\" #{params_str}"
          stdout, stderr, status = Open3.capture3(command_call)

          if not status.success?
            @logger.error("Error executing Mallet recognizer")
            @logger.error(stderr)
            @logger.error(stdout)
            raise Exception, "Mallet java command exited with #{status.exitstatus}. Check the log for a more detailed description of the error."
          end

          return stdout
        end

        def annotate_direct(text, options={})
          uri = Addressable::URI.new
          uri.query_values = options
          params = uri.query

          stdout = mallet_java_call(text, params)
          labels = stdout.split(" ")
          allAnnotations = {}

          labels.each do |label|
            category, sub_category = parse_label(label)
            hit = search_query(sub_category) unless (sub_category.nil?)

            unless hit.nil?
              resource_id = hit["resource_id"]
              allAnnotations[resource_id] = Annotation.new(resource_id, COGPO_RESOURCE_ID)
            end
          end

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
