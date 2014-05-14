# Require all necessary files in the appropriate order from here
# EX:
# require 'sparql_http'
# require 'ontologies_linked_data'
# require_relative 'dictionary/generator'

require 'zlib'
require 'redis'
require 'ontologies_linked_data'
require 'logger'
require 'benchmark'
require_relative 'annotation'
require_relative 'ncbo_annotator/mgrep/mgrep'
require_relative 'ncbo_annotator/config'
require_relative 'ncbo_annotator/monkeypatches'
require_relative 'ncbo_recommender'

# Require all models
project_root = File.dirname(File.absolute_path(__FILE__))
$ncbo_annotator_project_bin = project_root + '/../bin/'

module Annotator
  module Models

    class NcboAnnotator
      require_relative 'ncbo_annotator/recognizers/mallet'
      require_relative 'ncbo_annotator/recognizers/mgrep'

      REDIS_PREFIX_KEY = "current_instance"
      MGREP_DICTIONARY_REFRESH_TIMESTAMP = "mgrep_dict_refresh_stamp"
      LAST_MGREP_RESTART_TIMESTAMP = "last_mgrep_restart_stamp"

      DICTHOLDER = lambda {|prefix| "#{prefix}dict"}
      IDPREFIX = lambda {|prefix| "#{prefix}term:"}
      KEY_STORAGE = lambda {|prefix| "#{prefix}annotator:keys"}

      OCCURRENCE_DELIM = "|"
      LABEL_DELIM = ","
      DATA_TYPE_DELIM = "@@"
      CHUNK_SIZE = 500_000

      def initialize(logger=nil)
        @stop_words = Annotator.settings.stop_words_default_list
        @logger = logger ||= Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)
        redis_last_mgrep_restart_default_timestamp()
      end

      def stop_words=(stop_input)
        stop_input = stop_input.is_a?(String) ? stop_input.split(/\s*,\s*/) : stop_input.is_a?(Array) ? stop_input : [stop_input]
        @stop_words = Set.new(stop_input.map { |x| x.upcase })
      end

      def redis
        @redis ||= Redis.new(:host => Annotator.settings.annotator_redis_host,
                             :port => Annotator.settings.annotator_redis_port,
                             :timeout => 30)
        @redis
      end

      def redis_current_instance()
        redis = redis()
        cur_inst = redis.get(REDIS_PREFIX_KEY)
        raise Exception, "The Annotator Redis prefix key is not found!!! The prefix is required for Annotator to operate properly." if cur_inst.nil?
        return cur_inst
      end

      def redis_default_alternate_instance()
        val = redis_current_instance()
        return (val == Annotator.settings.annotator_redis_alt_prefix) ? Annotator.settings.annotator_redis_prefix : Annotator.settings.annotator_redis_alt_prefix
      end

      def create_term_cache(ontologies_filter=nil, delete_cache=false, redis_prefix=nil)
        ontologies = LinkedData::Models::Ontology.where.include(:acronym).all

        if ontologies_filter && ontologies_filter.length > 0
          in_list = []
          in_list_acronyms = []
          ontologies.each do |ont|
            if ontologies_filter.include?(ont.acronym)
              in_list << ont
              in_list_acronyms << ont.acronym
            end
          end
          ontologies = in_list
          not_found = ontologies_filter - in_list_acronyms
          @logger.error("Error: The following ontologies were not found in the system: #{not_found}") unless (not_found.empty?)
        end
        create_term_cache_from_ontologies(ontologies, delete_cache, redis_prefix)
      end

      def generate_dictionary_file()
        if Annotator.settings.mgrep_dictionary_file.nil?
          raise Exception, "mgrep_dictionary_file setting is nil"
        end

        redis = redis()
        cur_inst = redis_current_instance()
        dict_holder = DICTHOLDER.call(cur_inst)

        if (!redis.exists(dict_holder))
          raise Exception, "Generating an mgrep dictionary file requires a fully populated term cache. Please re-generate the cache and then re-run the dictionary generation."
        end

        all = redis.hgetall(dict_holder)
        # Create dict file
        outFile = File.new(Annotator.settings.mgrep_dictionary_file, "w")

        prefix_remove = Regexp.new(/^#{IDPREFIX.call(cur_inst)}/)
        windows_linebreak_remove = Regexp.new(/\r\n/)
        special_remove = Regexp.new(/[\r\n\t]/)

        all.each do |key, val|
          realKey = key.sub prefix_remove, ''
          realVal = val.gsub(windows_linebreak_remove, ' ').gsub(special_remove, ' ')
          outFile.puts("#{realKey}\t#{realVal}")
        end
        outFile.close
        redis_mgrep_dict_refresh_timestamp()
      end

      def create_term_cache_from_ontologies(ontologies, delete_cache=false, redis_prefix=nil)
        if (ontologies.nil? || ontologies.empty?)
          @logger.error("Error: The ontologies list appears to be empty. The Annotator cache creation process is terminated.")
          return
        end

        remaining_ontologies = ontologies.length
        @logger.info("There is a total of #{ontologies.length} ontolog#{ontologies.length > 1 ? "ies" : "y"} to cache.")

        redis = redis()
        cur_inst = redis_current_instance()
        redis_prefix ||= (delete_cache) ? redis_default_alternate_instance() : cur_inst
        @logger.info("The caching process is using Redis prefix: #{redis_prefix}. The Annotator is using Redis prefix: #{cur_inst}.")
        delete_term_cache(redis_prefix) if (delete_cache)

        ontologies.each_index do |i|
          ont = ontologies[i]
          last = ont.latest_submission(status: [:rdf])

          if last.nil?
            @logger.error("Error: Cannot find latest submission with 'RDF' parsed status for ontology: #{ont.id.to_s}")
          else
            @logger.info("Creating Annotator cache for #{ont.acronym} (#{last.id.to_s}) - #{i + 1}/#{ontologies.length} ontologies")
            create_term_cache_for_submission(@logger, last, redis, redis_prefix)
          end

          remaining_ontologies -= 1
          @logger.info("There is a total of #{remaining_ontologies} ontolog#{remaining_ontologies > 1 ? "ies" : "y"} remaining out of #{ontologies.length} ontologies") if (remaining_ontologies > 0)
        end

        @logger.info("Completed creating Annotator cache for all ontologies in the set using Redis prefix: #{redis_prefix}")
      end

      def delete_term_cache(redis_prefix)
        cur_inst = redis_current_instance()
        @logger.info("Deleting old redis data with Redis prefix: #{redis_prefix}. The Annotator currently uses Redis prefix: #{cur_inst}.")
        # remove old dictionary structure
        # use expire instead of del to allow potential clients to finish using the data
        key_expire_time = 120 # seconds

        time = Benchmark.realtime do
          redis.expire(DICTHOLDER.call(redis_prefix), key_expire_time)
          key_storage = KEY_STORAGE.call(redis_prefix)

          # remove all the stored keys
          class_keys = redis.lrange(key_storage, 0, CHUNK_SIZE)

          while !class_keys.empty?
            # use expire instead of del to allow potential clients to finish using the data
            redis.pipelined {
              class_keys.each {|key| redis.expire(key, key_expire_time)}
            }
            redis.ltrim(key_storage, CHUNK_SIZE + 1, -1) # Remove what we just deleted
            class_keys = redis.lrange(key_storage, 0, CHUNK_SIZE) # Get next chunk
          end
        end
        @logger.info("Completed deleting old redis data with Redis prefix: #{redis_prefix} in #{time} sec.")
      end

      def create_term_cache_for_submission(logger, sub, redis=nil, redis_prefix=nil)
        if (sub.nil?)
          logger.error("Error from Annotator.create_term_cache_for_submission: submission is nil")
          return
        end

        redis ||= redis()
        redis_prefix ||= redis_current_instance()

        page = 1
        size = 2500
        count_classes = 0
        status = LinkedData::Models::SubmissionStatus.find("ANNOTATOR").first

        begin
          #remove ANNOTATOR status before starting
          sub.bring_remaining()
          sub.remove_submission_status(status)
        rescue Exception => e
          msg = "Failed bring_remaining while caching classes for #{sub.id.to_s}"
          logger.error(msg)
          logger.error(e.message + "\n" + e.backtrace.join("\n\t"))
          return
        end

        begin
          time = Benchmark.realtime do
            sub.ontology.bring(:acronym) if sub.ontology.bring?(:acronym)
            ontResourceId = sub.ontology.id.to_s
            logger.info("Caching classes of #{sub.ontology.acronym}")

            paging = LinkedData::Models::Class.in(sub)
                .include(:prefLabel, :synonym, :definition, :semanticType).page(page, size)

            begin
              class_page = nil
              t0 = Time.now
              class_page = paging.all()
              count_classes += class_page.length
              logger.info("Page #{page} of #{class_page.total_pages} classes retrieved in #{Time.now - t0} sec.")

              t0 = Time.now

              class_page.each do |cls|
                resourceId = cls.id.to_s
                prefLabel = nil
                synonyms = []
                semanticTypes = []

                begin
                  prefLabel = cls.prefLabel
                  synonyms = cls.synonym || []
                  semanticTypes = cls.semanticType || []
                rescue Goo::Base::AttributeNotLoaded =>  e
                  msg = "Error loading attributes for class #{cls.id.to_s}"
                  backtrace = e.backtrace.join("\n\t")
                  logger.error(msg)
                  logger.error(backtrace)
                  next
                end

                next if prefLabel.nil? # Skip classes with no prefLabel
                synonyms.each do |syn|
                  create_term_entry(redis,
                                    redis_prefix,
                                    ontResourceId,
                                    resourceId,
                                    Annotator::Annotation::MATCH_TYPES[:type_synonym],
                                    syn,
                                    semanticTypes)
                end
                create_term_entry(redis,
                                  redis_prefix,
                                  ontResourceId,
                                  resourceId,
                                  Annotator::Annotation::MATCH_TYPES[:type_preferred_name],
                                  prefLabel,
                                  semanticTypes)
              end

              logger.info("Page #{page} of #{class_page.total_pages} cached in Annotator in #{Time.now - t0} sec.")
              page = class_page.next_page

              if page
                paging.page(page)
              end
            end while !page.nil?
          end

          # update submission status for Annotator
          sub.add_submission_status(status)
          sub.save()
          logger.info("Completed caching ontology: #{sub.ontology.acronym} (#{sub.id.to_s}) in #{time} sec. #{count_classes} classes.")
        rescue Exception => e
          msg = "Failed caching classes for #{sub.ontology.acronym} (#{sub.id.to_s})"
          logger.error(msg)
          logger.error(e.message + "\n" + e.backtrace.join("\n\t"))

          begin
            sub.add_submission_status(status.get_error_status())
            sub.save()
          rescue Exception => e
            msg = "Also, unable to add ANNOTATOR_ERROR status to #{sub.ontology.acronym} (#{sub.id.to_s})"
            logger.error(msg)
            logger.error(e.message + "\n" + e.backtrace.join("\n\t"))
          end
        end
      end

      ########################################
      # Possible options with their defaults:
      #   ontologies              = []
      #   semantic_types          = []
      #   filter_integers         = false
      #   expand_hierarchy_levels = 0
      #   expand_with_mappings    = false
      #   min_term_size           = nil
      #   whole_word_only         = true
      #   with_synonyms           = true
      #   longest_only            = false
      #######################################
      def annotate(text, options={})
        ontologies = options[:ontologies].is_a?(Array) ? options[:ontologies] : []
        expand_hierarchy_levels = options[:expand_hierarchy_levels].is_a?(Integer) ? options[:expand_hierarchy_levels] : 0
        expand_with_mappings = options[:expand_with_mappings] == true ? true : false

        annotations = annotate_direct(text, options)
        return annotations.values if annotations.length == 0

        if expand_hierarchy_levels > 0
          hierarchy_annotations = []
          expand_hierarchies(annotations, expand_hierarchy_levels, ontologies)
        end

        if expand_with_mappings
          expand_mappings(annotations, ontologies)
        end
        return annotations.values
      end

      def annotate_direct(text, options={})
        ontologies = options[:ontologies].is_a?(Array) ? options[:ontologies] : []
        semantic_types = options[:semantic_types].is_a?(Array) ? options[:semantic_types] : []
        filter_integers = options[:filter_integers] == true ? true : false
        min_term_size = options[:min_term_size].is_a?(Integer) ? options[:min_term_size] : nil
        whole_word_only = options[:whole_word_only] == false ? false : true
        with_synonyms = options[:with_synonyms] == false ? false : true
        longest_only = options[:longest_only] == true ? true : false

        client = Annotator::Mgrep::Client.new(Annotator.settings.mgrep_host, Annotator.settings.mgrep_port)
        rawAnnotations = client.annotate(text, false, whole_word_only)

        rawAnnotations.filter_integers() if filter_integers
        rawAnnotations.filter_min_size(min_term_size) unless min_term_size.nil?
        rawAnnotations.filter_stop_words(@stop_words)

        allAnnotations = {}
        longest_hits = {}
        redis_data = Hash.new
        cur_inst = redis_current_instance()

        redis.pipelined {
          rawAnnotations.each do |ann|
            id = get_prefixed_id(cur_inst, ann.string_id)
            redis_data[id] = { future: redis.hgetall(id) }
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

              id_group = ontResourceId + key
              unless allAnnotations.include?(id_group)
                allAnnotations[id_group] = Annotation.new(key, ontResourceId)
              end
              allAnnotations[id_group].add_annotation(ann.offset_from, ann.offset_to, typeAndOnt[0], ann.value)
              len = ann.offset_to - ann.offset_from + 1
              longest_hits[ann.offset_from] = len if (longest_hits[ann.offset_from].nil? || longest_hits[ann.offset_from] < len)
            end
          end
        end

        if (longest_only)
          allAnnotations.delete_if { |k, annotation|
            flag = true
            annotation.annotations.each do |ann|
              len = ann[:to] - ann[:from] + 1
              flag = false if longest_hits[ann[:from]] == len
            end
            flag
          }
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

          Goo.sparql_query_client.query(query,query_options: {rules: :NONE})
              .each do |sol|
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

      def expand_mappings(annotations, ontologies)
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
            acronym = mapped_term.ontology.id.to_s.split("/")[-1]

            if ontologies.length == 0 || ontologies.include?(mapped_term.ontology.id.to_s) || ontologies.include?(acronym)
              a.add_mapping(mapped_term.term.first.to_s, mapped_term.ontology.id.to_s)
            end
          end
        end
      end

      def get_prefixed_id_from_value(instance_prefix, val)
        # NCBO-696 - Remove case-sensitive variations on terms in annotator dictionary
        intId = Zlib::crc32(val.upcase())
        # intId = Zlib::crc32(val)
        return get_prefixed_id(instance_prefix, intId)
      end

      private

      def redis_mgrep_dict_refresh_timestamp()
        redis = redis()
        redis.set(MGREP_DICTIONARY_REFRESH_TIMESTAMP, Time.now)
      end

      def redis_last_mgrep_restart_default_timestamp()
        redis = redis()
        last_timestamp = redis.get(LAST_MGREP_RESTART_TIMESTAMP)
        redis.set(LAST_MGREP_RESTART_TIMESTAMP, Time.at(0)) unless last_timestamp
      end

      def create_term_entry(redis, instance_prefix, ontResourceId, resourceId, label_type, val, semanticTypes)
        # exclude single-character or empty/null values
        if (val.to_s.strip.length > 2)
          # NCBO-696 - Remove case-sensitive variations on terms in annotator dictionary
          val.upcase!()

          id = get_prefixed_id_from_value(instance_prefix, val)
          # populate dictionary structure
          redis.hset(DICTHOLDER.call(instance_prefix), id, val)
          entry = "#{label_type}#{LABEL_DELIM}#{ontResourceId}"

          # parse out semanticTypeCodes
          # always append them back to the original value
          semanticTypeCodes = get_semantic_type_codes(semanticTypes)
          semanticTypeCodes = (semanticTypeCodes.empty?) ? "" :
                                  "#{DATA_TYPE_DELIM}#{semanticTypeCodes}"
          matches = redis.hget(id, resourceId)

          if (matches.nil?)
            redis.hset(id, resourceId, "#{entry}#{semanticTypeCodes}")
          else
            rawMatches = matches.split(DATA_TYPE_DELIM)

            if (!rawMatches[0].include? entry)
              redis.hset(id, resourceId,
                         "#{rawMatches[0]}#{OCCURRENCE_DELIM}#{entry}#{semanticTypeCodes}")
            end
          end

          redis.rpush(KEY_STORAGE.call(instance_prefix), id) # Store key for easy delete
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

      def get_prefixed_id(instance_prefix, intId)
        return "#{IDPREFIX.call(instance_prefix)}#{intId}"
      end

      def mappings_for_class_ids(class_ids)
        mappings = []
        class_ids.each do |c|
          query = LinkedData::Models::Mapping.where(terms: [ term: RDF::URI.new(c) ])
          query.include(:process)
          query.include(terms: [ :ontology, :term ])
          mappings.select { |m| !m.to_s }
          maps_to_filter = query.all
          maps = []
          maps_to_filter.each do |m|
            m.process.each do |p|
              if !(p.id.to_s["loom"] || p.id.to_s["same_uris"])
                maps << m
                break
              end
            end
          end
          mappings += maps
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

