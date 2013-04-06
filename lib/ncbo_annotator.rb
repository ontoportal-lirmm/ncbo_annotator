# Require all necessary files in the appropriate order from here
# EX:
# require 'sparql_http'
# require 'ontologies_linked_data'
# require_relative 'dictionary/generator'

require 'zlib'
require 'redis'
require 'ontologies_linked_data'
require_relative "../config/config.rb"
require_relative 'ncbo_annotator/mgrep/mgrep'

module Annotator
  module Models

    class NcboAnnotator

      LABELPREF = "PREF"
      LABELSYN = "SYN"
      DICTHOLDER = "dict"
      IDPREFIX = "term:"

      def create_term_cache()
        page = 1
        size = 2500
        redis = Redis.new

        # remove all dictionary structure
        redis.del(DICTHOLDER)

        LinkedData::Models::Ontology.all.each do |ont|
          last = ont.latest_submission
          acronym = ont.acronym.value

          if (!last.nil?)
            begin
              class_page = LinkedData::Models::Class.page submission: last, page: page, size: size,
                                                          load_attrs: { prefLabel: true, synonym: true, definition: true }
              class_page.each do |cls|
                prefLabel = cls.prefLabel.value
                resourceId = cls.resource_id.value
                synonyms = cls.synonym

                (synonyms || []).map { |syn|
                  create_term_entry(redis, acronym, resourceId, LABELSYN, syn.value)
                }
                create_term_entry(redis, acronym, resourceId, LABELPREF, prefLabel)
              end
              page = class_page.next_page
            end while !page.nil?
          end
        end
      end

      def generate_dictionary_file()
        redis = Redis.new

        if (!redis.exists(DICTHOLDER))
          create_term_cache()
        end

        all = redis.hgetall(DICTHOLDER)
        # Create dict file
        outFile = File.new($MGREP_DICTIONARY_FILE, "w")

        all.each do |key, val|
          realKey = key.sub /^#{IDPREFIX}/, ''
          outFile.puts("#{realKey}\t#{val}")
        end
        outFile.close
      end

      private

      def create_term_entry(redis, acronym, resourceId, label, val)
        labelInt = Zlib::crc32(val)
        id = "#{IDPREFIX}#{labelInt}"
        entry = "#{label},#{acronym}"
        matches = redis.hget(id, resourceId)

        if (matches.nil? || !redis.hexists(DICTHOLDER, id))
          redis.hset(id, resourceId, entry)
        elsif (!matches.include? entry)
          redis.hset(id, resourceId, "#{matches}:#{entry}")
        end

        # populate dictionary structure
        redis.hset(DICTHOLDER, id, val)
      end
    end
  end
end

