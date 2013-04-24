# Require all necessary files in the appropriate order from here
# EX:
# require 'sparql_http'
# require 'ontologies_linked_data'
# require_relative 'dictionary/generator'

require 'zlib'
require 'redis'
require 'ontologies_linked_data'
require_relative 'annotation'
require_relative 'ncbo_annotator/mgrep/mgrep'
require_relative 'ncbo_annotator/config'

module Annotator
  module Models

    class NcboAnnotator

      DICTHOLDER = "dict"
      IDPREFIX = "term:"
      OCCURENCE_DELIM = "|"
      LABEL_DELIM = ","
      DIRECT_ANNOTATIONS_LABEL = "directAnnotations"

      def create_term_cache_from_ontologies(ontologies)
        page = 1
        size = 2500
        redis = Redis.new(:host => LinkedData.settings.redis_host, :port => LinkedData.settings.redis_port)

        # remove old dictionary structure
        redis.del(DICTHOLDER)
        # remove term cache
        termKeys = redis.keys("#{IDPREFIX}*") || []
        redis.del(termKeys) unless termKeys.empty?

        ontologies.each do |ont|
          last = ont.latest_submission
          ontResourceId = ont.resource_id.value

          if (!last.nil?)
            begin
              class_page = LinkedData::Models::Class.page submission: last, page: page, size: size,
                                                          load_attrs: { prefLabel: true, synonym: true, definition: true }
              class_page.each do |cls|
                prefLabel = cls.prefLabel.value
                resourceId = cls.resource_id.value
                synonyms = cls.synonym || []

                synonyms.each do |syn|
                  create_term_entry(redis, ontResourceId, resourceId, Annotator::Annotation::MATCH_TYPES[:type_synonym], syn.value)
                end
                create_term_entry(redis, ontResourceId, resourceId, Annotator::Annotation::MATCH_TYPES[:type_preferred_name], prefLabel)
              end
              page = class_page.next_page
            end while !page.nil?
          end
        end
      end

      def create_term_cache()
        ontologies = LinkedData::Models::Ontology.all
        create_term_cache_from_ontologies(ontologies)
      end

      def generate_dictionary_file()
        redis = Redis.new(:host => LinkedData.settings.redis_host, :port => LinkedData.settings.redis_port)

        if (!redis.exists(DICTHOLDER))
          create_term_cache()
        end

        all = redis.hgetall(DICTHOLDER)
        # Create dict file
        outFile = File.new(Annotator.settings.mgrep_dictionary_file, "w")

        all.each do |key, val|
          realKey = key.sub /^#{IDPREFIX}/, ''
          outFile.puts("#{realKey}\t#{val}")
        end
        outFile.close
      end

      def annotate(text, ontologies=[])
        return annotate_direct(text, ontologies)
      end

      def annotate_direct(text, ontologies=[])
        ontology_acronyms_as_resource_ids(ontologies)
        redis = Redis.new(:host => LinkedData.settings.redis_host, :port => LinkedData.settings.redis_port)
        client = Annotator::Mgrep::Client.new(Annotator.settings.mgrep_host, Annotator.settings.mgrep_port)
        rawAnnotations = client.annotate(text, true)
        allAnnotations = []

        rawAnnotations.each do |ann|
          id = get_prefixed_id(ann.string_id)
          matches = redis.hgetall(id)

          matches.each do |key, val|
            allVals = val.split(OCCURENCE_DELIM)

            allVals.each do |eachVal|
              typeAndOnt = eachVal.split(LABEL_DELIM)
              ontResourceId = typeAndOnt[1]

              if (ontologies.empty? || ontologies.include?(ontResourceId))
                annotatedClass = {
                    "id" => key,
                    "ontology" => ontResourceId
                }
                annotation = Annotation.new(ann.offset_from, ann.offset_to, typeAndOnt[0], annotatedClass)
                allAnnotations.push(annotation)
              end
            end
          end
        end
        return { "#{DIRECT_ANNOTATIONS_LABEL}" => allAnnotations }
      end

      def get_prefixed_id_from_value(val)
        intId = Zlib::crc32(val)
        return get_prefixed_id(intId)
      end

      private

      def ontology_acronyms_as_resource_ids(ontologies)
        url_prefix = LinkedData::Models::Ontology.resource_id_prefix

        ontologies.each do |ont|
          if !ont.match(/^#{url_prefix}/)
             ont.insert(0, url_prefix)
          end
        end
      end

      def create_term_entry(redis, ontResourceId, resourceId, label, val)
        # exclude single-character or empty/null values
        if (val.to_s.strip.length > 1)
          id = get_prefixed_id_from_value(val)
          entry = "#{label}#{LABEL_DELIM}#{ontResourceId}"
          matches = redis.hget(id, resourceId)

          # populate dictionary structure
          redis.hset(DICTHOLDER, id, val)

          if (matches.nil?)
            redis.hset(id, resourceId, entry)
          elsif (!matches.include? entry)
            redis.hset(id, resourceId, "#{matches}#{OCCURENCE_DELIM}#{entry}")
          end
        end
      end

      def get_prefixed_id(intId)
        return "#{IDPREFIX}#{intId}"
      end
    end
  end
end

