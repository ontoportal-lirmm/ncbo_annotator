lib/ncbo_annotator.rbrequire 'open3'
require 'logger'
require 'addressable/uri'
require_relative '../unitex/unitex_client'

module Annotator
  module Models
    module Recognizers

      class Unitex < Annotator::Models::NcboAnnotator


        def initialize()
          super()
          @client = Annotator::Unitex::Client.new(Annotator.settings.unitex_host, Annotator.settings.unitex_port, Annotator.settings.unitex_host, Annotator.settings.unitex_port)
          @stop_words = Annotator.settings.stop_words_default_list
          @logger = Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)
        end

        def redis
          @redis ||= Redis.new(:host => Annotator.settings.annotator_redis_host,
                               :port => Annotator.settings.annotator_redis_port,
                               :timeout => 30)
        end

        def redis_current_instance()
          redis = redis()
          cur_inst = redis.get(REDIS_PREFIX_KEY)

          if cur_inst.nil?
            redis.set(REDIS_PREFIX_KEY, Annotator.settings.annotator_redis_prefix)
            cur_inst = redis.get(REDIS_PREFIX_KEY)
          end

          cur_inst
        end

        def redis_default_alternate_instance()
          val = redis_current_instance
          (val == Annotator.settings.annotator_redis_alt_prefix) ? Annotator.settings.annotator_redis_prefix : Annotator.settings.annotator_redis_alt_prefix
        end

        def redis_switch_instance(inst=nil)
          redis = redis()
          val = redis_current_instance
          inst ||= redis_default_alternate_instance
          redis.set(REDIS_PREFIX_KEY, inst)
          @logger.info("Swapping Annotator Redis instance from #{val} to #{inst}.")
        end


        def annotate_direct(text, options={})
          uri = Addressable::URI.new
          uri.query_values = options
          params = uri.query

          ontologies = options[:ontologies].is_a?(Array) ? options[:ontologies] : []
          semantic_types = options[:semantic_types].is_a?(Array) ? options[:semantic_types] : []
          use_semantic_types_hierarchy = options[:use_semantic_types_hierarchy] == true ? true : false
          filter_integers = options[:filter_integers] == true ? true : false
          min_term_size = options[:min_term_size].is_a?(Integer) ? options[:min_term_size] : nil
          whole_word_only = options[:whole_word_only] == false ? false : true
          with_synonyms = options[:with_synonyms] == false ? false : true
          longest_only = options[:longest_only] == true ? true : false
          lemmatize = options[:lemmatize] == "true" ? true : false

          rawAnnotations = @client.annotate(text, longest_only)


          rawAnnotations.filter_integers() if filter_integers
          rawAnnotations.filter_min_size(min_term_size) unless min_term_size.nil?
          rawAnnotations.filter_stop_words(@stop_words)

          if (use_semantic_types_hierarchy)
            semantic_types = expand_semantic_types_hierarchy(semantic_types)
          end

          allAnnotations = {}
          flattenedAnnotations = Array.new

          redis_data = Hash.new
          cur_inst = redis_current_instance()

          redis.pipelined {
            rawAnnotations.each do |ann|
              id = get_prefixed_id(cur_inst, ann.string_id)
              redis_data[id] = {future: redis.hgetall(id)}
            end
          }
          sleep(1.0 / 150.0)
          redis_data.each do |k, v|
            while v[:future].value.is_a?(Redis::FutureNotReady)
              sleep(1.0 / 150.0)
            end
          end

          rawAnnotations.each do |ann|
            id = get_prefixed_id(cur_inst, ann.string_id)
            matches = redis_data[id][:future].value

            # key = resourceId (class)
            matches.each do |key, val|
              dataTypeVals = val.split(DATA_TYPE_DELIM)
              classSemanticTypes = (dataTypeVals.length > 1) ? dataTypeVals[1].split(LABEL_DELIM) : []
              allVals = dataTypeVals[0].split(OCCURRENCE_DELIM)

              # check that class semantic types contain at least one requested semantic type
              next if !semantic_types.empty? && (semantic_types & classSemanticTypes).empty?

              allVals.each do |eachVal|
                typeAndOnt = eachVal.split(LABEL_DELIM)
                recordType = typeAndOnt[0]
                next if recordType == Annotator::Annotation::MATCH_TYPES[:type_synonym] && !with_synonyms
                ontResourceId = typeAndOnt[1]
                acronym = ontResourceId.to_s.split('/')[-1]
                next if !ontologies.empty? && !ontologies.include?(ontResourceId) && !ontologies.include?(acronym)

                if (longest_only)
                  annotation = Annotation.new(key, ontResourceId)
                  if (lemmatize)
                    annotation.add_annotation(convert_from(regex_indexes, ann.offset_from), convert_to(regex_indexes, ann.offset_to), typeAndOnt[0], ann.value)
                  else
                    annotation.add_annotation(ann.offset_from, ann.offset_to, typeAndOnt[0], ann.value)
                  end
                  flattenedAnnotations << annotation
                else
                  id_group = ontResourceId + key

                  unless allAnnotations.include?(id_group)
                    allAnnotations[id_group] = Annotation.new(key, ontResourceId)
                  end
                  if (lemmatize)
                    indexFrom = convert_from(regex_indexes, ann.offset_from)
                    indexTo = convert_to(regex_indexes, ann.offset_to)
                    if (indexFrom==0 || indexTo==0)
                      raise Exception, "Converting lemmatized index to original index failed."
                    end
                    allAnnotations[id_group].add_annotation(indexFrom, indexTo, typeAndOnt[0], ann.value)
                  else
                    allAnnotations[id_group].add_annotation(ann.offset_from, ann.offset_to, typeAndOnt[0], ann.value)
                  end
                end
              end
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
          RSolr.solr_escape(text).gsub(/\s+/, "\\ ")
        end

        def parse_label(full_label)
          category = CATEGORIES.select { |cat, lbl| full_label.start_with?(cat) }
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

