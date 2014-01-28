require 'open3'
require 'logger'

module Annotator
  module Models
    module Recognizers

      class Mallet < Annotator::Models::NcboAnnotator

        CATEGORIES = {
          "StimulusModality" => "Stimulus Modality",
          "StimulusType" => "Stimulus Type",
          "ResponseModality" => "Response Modality",
          "ResponseType" => "Response Type",
          "Instructions" => "Instructions"
        }

        COGPO_ACRONYM = "COGPO"
        COGPO_RESOURCE_ID = "http://data.bioontology.org/ontologies/#{COGPO_ACRONYM}"

        def initialize
          super()
          @mallet_jar_path = $project_bin + "mallet.jar"
          @mallet_deps_jar_path = $project_bin + "mallet_deps.jar"
        end

        def mallet_java_call(text)
          #command_call = "java -cp \"#{$project_bin}.:#{$project_bin}mallet.jar:#{$project_bin}mallet-deps.jar:#{$project_bin}*\" BasicClassifier string \"hello world\""
          command_call = "java -cp \"#{$project_bin}.:#{$project_bin}*\" BasicClassifier string \"#{Shellwords.escape(text)}\""
          stdout, stderr, status = Open3.capture3(command_call)

          if not status.success?
            @logger.error("Error executing Mallet recognizer")
            @logger.error(stderr)
            @logger.error(stdout)
            raise Exception, "Mallet java command exited with #{status.exitstatus}. Check parser logs."
          end

          return stdout
        end

        def annotate_direct(text, options={})
          stdout = mallet_java_call(text)
          labels = stdout.split(" ")
          allAnnotations = {}

          labels.each do |label|
            category, sub_category = parse_label(label)

            hit = search_query(category) unless (category.nil?)

            unless hit.nil?
              resource_id = hit["resource_id"]
              allAnnotations[resource_id] = Annotation.new(resource_id, COGPO_RESOURCE_ID)
            end

            hit = search_query(sub_category) unless (sub_category.nil?)

            unless hit.nil?
              resource_id = hit["resource_id"]
              allAnnotations[resource_id] = Annotation.new(resource_id, COGPO_RESOURCE_ID)
            end
          end

          return allAnnotations
        end

        def search_query(label)
          query = "\"#{RSolr.escape(label)}\""
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
