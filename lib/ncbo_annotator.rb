# Require all necessary files in the appropriate order from here
# EX:
# require 'sparql_http'
# require 'ontologies_linked_data'
# require_relative 'dictionary/generator'

require 'zlib'
require 'redis'
require 'ontologies_linked_data'
require 'logger'
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

      def create_term_cache_from_ontologies(ontologies)
        page = 1
        size = 2500
        redis = Redis.new(:host => LinkedData.settings.redis_host, :port => LinkedData.settings.redis_port)

        # Get logger
        logger = Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)

        # remove old dictionary structure
        redis.del(DICTHOLDER)
        # remove term cache
        termKeys = redis.keys("#{IDPREFIX}*") || []
        redis.del(termKeys) unless termKeys.empty?

        ontologies.each do |ont|
          last = ont.latest_submission
          ontResourceId = ont.resource_id.value
          logger.info("Caching classes from #{ont.acronym}"); logger.flush

          if (!last.nil?)
            begin
              begin
                class_page = LinkedData::Models::Class.page submission: last, page: page, size: size,
                                                            load_attrs: { prefLabel: true, synonym: true, definition: true }
              rescue
                # If page fails, skip to next ontology
                logger.info("Failed caching classes for #{ont.acronym}"); logger.flush
                page = nil
                next
              end
              
              class_page.each do |cls|
                prefLabel = cls.prefLabel.value rescue next # Skip classes with no prefLabel
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

        prefix_remove = Regexp.new(/^#{IDPREFIX}/)
        windows_linebreak_remove = Regexp.new(/\r\n/)
        special_remove = Regexp.new(/[\r\n\t]/)
        all.each do |key, val|
          realKey = key.sub prefix_remove, ''
          realVal = val.gsub(windows_linebreak_remove, ' ').gsub(special_remove, ' ')
          outFile.puts("#{realKey}\t#{realVal}")
        end
        outFile.close
      end

      def annotate(text, ontologies=[], expand_hierachy_levels=0, filter_integers=false)
        annotations = annotate_direct(text, ontologies, filter_integers)
        return annotations.values if expand_hierachy_levels == 0
        hierarchy_annotations = []
        expand_hierarchies(annotations, expand_hierachy_levels, ontologies)
        return annotations.values
      end

      def annotate_direct(text, ontologies=[], filter_integers=false)
        redis = Redis.new(:host => LinkedData.settings.redis_host, :port => LinkedData.settings.redis_port)
        client = Annotator::Mgrep::Client.new(Annotator.settings.mgrep_host, Annotator.settings.mgrep_port)
        rawAnnotations = client.annotate(text, true)
        rawAnnotations.filter_integers() if filter_integers

        allAnnotations = {}

        rawAnnotations.each do |ann|
          id = get_prefixed_id(ann.string_id)
          matches = redis.hgetall(id)

          matches.each do |key, val|
            allVals = val.split(OCCURENCE_DELIM)

            allVals.each do |eachVal|
              typeAndOnt = eachVal.split(LABEL_DELIM)
              ontResourceId = typeAndOnt[1]
              next if !ontologies.empty? && !ontologies.include?(ontResourceId)

              id_group = ontResourceId + key
              unless allAnnotations.include?(id_group)
                allAnnotations[id_group] = Annotation.new(key, ontResourceId)
              end
              allAnnotations[id_group].add_annotation(ann.offset_from, ann.offset_to, typeAndOnt[0])
            end
          end
        end
        return allAnnotations
      end

      def expand_hierarchies(annotations, levels, ontologies)
        current_level = 1

        while current_level <= levels do

          indirect = {}
          level_ids = []
          annotations.each do |k,a|
            if current_level == 1
              level_ids << a.annotatedClass.resource_id.value
            else
              if a.hierarchy.last.distance == (current_level -1)
                cls = a.hierarchy.last.annotatedClass
                level_ids << cls.resource_id.value
                id_group = cls.submissionAcronym.first.value + cls.resource_id.value 

                #this is to maintain the link from indirect parents
                indirect[id_group] = !indirect[id_group] ? [k] : (indirect[id_group] << k)
              end
            end
          end
          return if level_ids.length == 0
          query = hierarchy_query(level_ids)
          Goo.store.query(query).each_solution do |sol|
            id = sol.get(:id).value
            parent = sol.get(:parent).value
            ontology = sol.get(:graph).value
            ontology = ontology[0..ontology.index("submissions")-2]
            #
            #TODO in next full parsing this can be removed
            ontology["/metadata"] = ""
            id_group = ontology + id
            if annotations.include? id_group
              annotations[id_group].add_parent(parent, current_level)
            end
            if indirect[id_group]
              indirect[id_group].each do |k|
                annotations[k].add_parent(parent, current_level)
              end
            end
          end
          current_level += 1
        end

      end

      def get_prefixed_id_from_value(val)
        intId = Zlib::crc32(val)
        return get_prefixed_id(intId)
      end

      private

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

      def hierarchy_query(class_ids)
        filter_ids = class_ids.map { |id| "?id = <#{id}>" } .join " || "
        query = <<eos
SELECT DISTINCT ?id ?parent ?graph WHERE { GRAPH ?graph { ?id <http://www.w3.org/2000/01/rdf-schema#subClassOf> ?parent . }
FILTER (#{filter_ids})
}
eos
       return query
      end
    end
  end
end

