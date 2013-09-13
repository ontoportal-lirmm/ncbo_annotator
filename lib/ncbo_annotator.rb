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
require_relative 'ncbo_annotator/monkeypatches'
require_relative 'ncbo_recommender'

module Annotator
  module Models

    class NcboAnnotator

      DICTHOLDER = "dict"
      IDPREFIX = "term:"
      OCCURRENCE_DELIM = "|"
      LABEL_DELIM = ","
      DATA_TYPE_DELIM = "@@"
      KEY_STORAGE = "annotator:keys"
      CHUNK_SIZE = 500_000

      def initialize()
        @stop_words = Annotator.settings.stop_words_default_list
      end

      def stop_words=(stop_input)
        @stop_words = Set.new(stop_input.map { |x| x.upcase })
      end
      
      def create_term_cache_from_ontologies(ontologies, delete_cache=false)
        page = 1
        size = 2500
        redis = Redis.new(:host => LinkedData.settings.redis_host, 
                          :port => LinkedData.settings.redis_port)

        # Get logger
        logger = Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)

        if delete_cache
          logger.info("Deleting old redis data")
          logger.flush

          # remove old dictionary structure
          redis.del(DICTHOLDER)
          
          # remove all the stored keys
          class_keys = redis.lrange(KEY_STORAGE, 0, CHUNK_SIZE)

          while !class_keys.empty?
            redis.del(class_keys)
            redis.ltrim(KEY_STORAGE, CHUNK_SIZE + 1, -1) # Remove what we just deleted
            class_keys = redis.lrange(KEY_STORAGE, 0, CHUNK_SIZE) # Get next chunk
          end
        end

        ontologies.each do |ont|
          last = ont.latest_submission(status: [:rdf])
          create_cache_for_submission(logger, last, redis)
        end
      end

      def create_cache_for_submission(logger, sub, redis=nil)
        page = 1
        size = 2500
        redis ||= Redis.new(:host => LinkedData.settings.redis_host,
                            :port => LinkedData.settings.redis_port)
        sub.bring(:ontology) if sub.bring?(:ontology)
        sub.ontology.bring(:acronym) if sub.ontology.bring?(:acronym)
        ontResourceId = sub.ontology.id.to_s
        logger.info("Caching classes from #{sub.ontology.acronym}")
        logger.flush

        paging = LinkedData::Models::Class.in(sub)
            .include(:prefLabel, :synonym, :definition, :semanticType)
            .page(1, size)

        if (!sub.nil?)
          begin
            class_page = nil

            begin
              class_page = paging.all
            rescue
              # If page fails, stop processing of this submission
              logger.info("Failed caching classes for #{sub.ontology.acronym}")
              logger.flush
              return
            end

            class_page.each do |cls|
              prefLabel = cls.prefLabel
              next if prefLabel.nil? # Skip classes with no prefLabel
              resourceId = cls.id.to_s
              synonyms = cls.synonym || []
              semanticTypes = cls.semanticType || []

              synonyms.each do |syn|
                create_term_entry(redis, ontResourceId, resourceId, Annotator::Annotation::MATCH_TYPES[:type_synonym], syn, semanticTypes)
              end
              create_term_entry(redis, ontResourceId, resourceId, Annotator::Annotation::MATCH_TYPES[:type_preferred_name], prefLabel, semanticTypes)
            end
            page = class_page.next_page

            if page
              paging.page(page)
            end
          end while !page.nil?
        end
      end

      def create_term_cache(ontologies_filter=nil, delete_cache=false)
        ontologies = LinkedData::Models::Ontology.where.include(:acronym).all
        if ontologies_filter && ontologies_filter.length > 0
          in_list = []
          ontologies.each do |ont|
            in_list << ont if ontologies_filter.include?(ont.acronym)
          end
          ontologies = in_list
        end
        create_term_cache_from_ontologies(ontologies, delete_cache=delete_cache)
      end

      def generate_dictionary_file()
        if Annotator.settings.mgrep_dictionary_file.nil?
          raise Exception, "mgrep_dictionary_file setting is nil"
        end

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

      def annotate(text, ontologies=[], semantic_types=[], 
                   filter_integers=false, 
                   expand_hierachy_levels=0,
                   expand_with_mappings=false,
                   min_term_size=nil)

        annotations = annotate_direct(text, ontologies, semantic_types, filter_integers, min_term_size)
        return annotations.values if annotations.length == 0
        if expand_hierachy_levels > 0
          hierarchy_annotations = []
          expand_hierarchies(annotations, expand_hierachy_levels, ontologies)
        end
        if expand_with_mappings
          expand_mappings(annotations, ontologies)
        end
        return annotations.values
      end

      def annotate_direct(text, ontologies=[], semantic_types=[], filter_integers=false,min_term_size=nil)
        redis = Redis.new(:host => LinkedData.settings.redis_host, :port => LinkedData.settings.redis_port)
        client = Annotator::Mgrep::Client.new(Annotator.settings.mgrep_host, Annotator.settings.mgrep_port)
        rawAnnotations = client.annotate(text, false)

        rawAnnotations.filter_integers() if filter_integers
        rawAnnotations.filter_min_size(min_term_size) unless min_term_size.nil?

        rawAnnotations.filter_stop_words(@stop_words)

        allAnnotations = {}

        rawAnnotations.each do |ann|
          id = get_prefixed_id(ann.string_id)
          matches = redis.hgetall(id)

          # key = resourceId (class)
          matches.each do |key, val|
            dataTypeVals = val.split(DATA_TYPE_DELIM)
            classSemanticTypes = (dataTypeVals.length > 1) ? dataTypeVals[1].split(LABEL_DELIM) : []
            allVals = dataTypeVals[0].split(OCCURRENCE_DELIM)

            # check that class semantic types contain at least one requested semantic type
            next if !semantic_types.empty? && (semantic_types & classSemanticTypes).empty?

            allVals.each do |eachVal|
              typeAndOnt = eachVal.split(LABEL_DELIM)
              ontResourceId = typeAndOnt[1]
              acronym = ontResourceId.to_s.split('/')[-1]
              next if !ontologies.empty? && !ontologies.include?(ontResourceId) && !ontologies.include?(acronym)

              id_group = ontResourceId + key
              unless allAnnotations.include?(id_group)
                allAnnotations[id_group] = Annotation.new(key, ontResourceId)
              end
              allAnnotations[id_group].add_annotation(ann.offset_from, ann.offset_to, typeAndOnt[0], ann.value)
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
              level_ids << a.annotatedClass.id.to_s
            else
              if !a.hierarchy.last.nil?
                if a.hierarchy.last.distance == (current_level -1)
                  cls = a.hierarchy.last.annotatedClass
                  level_ids << cls.id.to_s
                  id_group = cls.submission.ontology.id.to_s + cls.id.to_s

                  #this is to maintain the link from indirect parents
                  indirect[id_group] = !indirect[id_group] ? [k] : (indirect[id_group] << k)
                end
              end
            end
          end
          return if level_ids.length == 0
          query = hierarchy_query(level_ids)
          Goo.sparql_query_client.query(query).each do |sol|
            id = sol[:id].to_s
            parent = sol[:parent].to_s
            ontology = sol[:graph].to_s
            ontology = ontology[0..ontology.index("submissions")-2]
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

      def expand_mappings(annotations,ontologies)
        class_ids = []
        annotations.each do |k,a|
          class_ids << a.annotatedClass.id.to_s
        end
        mappings = mappings_for_class_ids(class_ids)
        mappings.each do |mapping|
          annotations.each do |k,a|
            mapped_term = mapping.terms.select { |t| t.term.first.to_s != a.annotatedClass.id.to_s }
            next if mapped_term.length == mapping.terms.length || mapped_term.length == 0
            mapped_term = mapped_term.first
            binding.pry if mapped_term.nil?
            acronym = mapped_term.ontology.id.to_s.split("/")[-1]
            if ontologies.length == 0 || ontologies.include?(mapped_term.ontology.id.to_s) || ontologies.include?(acronym)
              a.add_mapping(mapped_term.term.first.to_s,mapped_term.ontology.id.to_s)
            end
          end
        end
      end

      def get_prefixed_id_from_value(val)
        intId = Zlib::crc32(val)
        return get_prefixed_id(intId)
      end

      private

      def create_term_entry(redis, ontResourceId, resourceId, label, val, semanticTypes)
        # exclude single-character or empty/null values
        if (val.to_s.strip.length > 2)
          id = get_prefixed_id_from_value(val)
          # populate dictionary structure
          redis.hset(DICTHOLDER, id, val)
          entry = "#{label}#{LABEL_DELIM}#{ontResourceId}"

          # parse out semanticTypeCodes
          # always append them back to the original value
          semanticTypeCodes = get_semantic_type_codes(semanticTypes)
          semanticTypeCodes = (semanticTypeCodes.empty?) ? "" : "#{DATA_TYPE_DELIM}#{semanticTypeCodes}"
          matches = redis.hget(id, resourceId)

          if (matches.nil?)
            redis.hset(id, resourceId, "#{entry}#{semanticTypeCodes}")
          else
            rawMatches = matches.split(DATA_TYPE_DELIM)

            if (!rawMatches[0].include? entry)
              redis.hset(id, resourceId, "#{rawMatches[0]}#{OCCURRENCE_DELIM}#{entry}#{semanticTypeCodes}")
            end
          end

          redis.rpush(KEY_STORAGE, id) # Store key for easy delete
        end
      end

      def get_semantic_type_codes(semanticTypes)
        semanticTypeCodes = ""
        i = 0
        semanticTypes.each do |semanticType|
          val = semanticType.to_s.split('/')[-1]
          if i > 0
            semanticTypeCodes << ","
          end
          semanticTypeCodes << val
          i += 1
        end
        return semanticTypeCodes
      end

      def get_prefixed_id(intId)
        return "#{IDPREFIX}#{intId}"
      end

      def mappings_for_class_ids(class_ids)
        mappings = []
        class_ids.each do |c|
          query = LinkedData::Models::Mapping.where(terms: [ term: RDF::URI.new(c) ])
          query.include(terms: [ :ontology, :term ])
          mappings +=  query.all
        end

        #TODO there is a bug in the data
        #and some mappings do not have two terms
        #this can be removed once the data is fixed
        result = []
        mappings.each do |m|
          count = 0
          m.terms.each do |t|
            count += 1 if t.loaded_attributes.include?(:term)
          end
          result << m if count == 2
        end
        mappings = result
        #end TODO
        return mappings
      end

      def hierarchy_query(class_ids)
        filter_ids = class_ids.map { |id| "?id = <#{id}>" } .join " || "
        query = <<eos
SELECT DISTINCT ?id ?parent ?graph WHERE { GRAPH ?graph { ?id <http://www.w3.org/2000/01/rdf-schema#subClassOf> ?parent . }
FILTER (#{filter_ids})
FILTER (!isBlank(?parent))
FILTER (?parent != <http://www.w3.org/2002/07/owl#Thing>)
}
eos
       return query
      end
    end
  end
end

