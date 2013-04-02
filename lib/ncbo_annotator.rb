# Require all necessary files in the appropriate order from here
# EX:
# require 'sparql_http'
# require 'ontologies_linked_data'
# require_relative 'dictionary/generator'

require 'zlib'
require 'redis'
require 'ontologies_linked_data'

module Annotator
  module Models

    class NcboAnnotator

      def create_dictionary
        page = 1
        size = 2500
        redis = Redis.new

        # Create dict file
        outFile = File.new("dict.txt", "w")

        LinkedData::Models::Ontology.all.each do |ont|
          last = ont.latest_submission()

          begin
            class_page = LinkedData::Models::Class.page submission: last, page: page, size: size,
                                                        load_attrs: { prefLabel: true, synonym: true, definition: true }
            class_page.each do |cls|
              prefLabel = cls.prefLabel.to_s
              id = Zlib::crc32(prefLabel)

              if (!redis.exists(id))

                redis.set(id, prefLabel)


                outFile.puts("#{id}\t#{prefLabel}")
              end

            end
            page = class_page.next_page
          end while !page.nil?
        end

        outFile.close

      end


    end

  end
end

