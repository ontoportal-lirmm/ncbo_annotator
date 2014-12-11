require 'logger'
require 'ontologies_linked_data'
require_relative 'recommendation'

module Recommender
  module Models

    class NcboRecommender

      def initialize()
        @logger = Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)
      end

      DEFAULT_HIERARCHY_LEVELS = 5

      def recommend(text, ontologies=[], include_classes=false)
        annotator = Annotator::Models::NcboAnnotator.new
        annotations = annotator.annotate(text, {
            ontologies: ontologies,
            semantic_types: [],
            filter_integers: false,
            expand_class_hierarchy: true,
            expand_hierarchy_levels: DEFAULT_HIERARCHY_LEVELS,
            expand_with_mappings: false,
            min_term_size: nil,
            whole_word_only: true,
            with_synonyms: true
        })

        recommendations = {}
        classes_matched = []

        annotations.each do |ann|
          classId = ann.annotatedClass.id.to_s
          ont = ann.annotatedClass.submission.ontology
          ontologyId = ont.id.to_s

          unless recommendations.include?(ontologyId)
            cls_count = get_ontology_class_count(ont)
            next if cls_count <= 0  # skip any ontologies without a ready latest submission
            recommendations[ontologyId] = Recommendation.new
            recommendations[ontologyId].ontology = ont
            recommendations[ontologyId].numTermsTotal = cls_count
          end

          rec = recommendations[ontologyId]
          cls_ont_key = "#{classId}_#{ontologyId}"
          unless classes_matched.include?(cls_ont_key)
            classes_matched << cls_ont_key
            rec.annotatedClasses << ann.annotatedClass if include_classes
            rec.numTermsMatched += 1
          end
          rec.increment_score(ann)
        end

        recommendations.values.each {|v| v.normalize_score}
        return recommendations.values.sort {|a,b| b.score <=> a.score}
      end


      private

      def get_ontology_class_count(ont)
        sub = nil
        begin
          #TODO: there appears to be a bug that does not allow retrieving submission by its id
          # because the id is incorrect. The workaround is to get the ontology object and
          # then retrieve its latest submission.
          sub = LinkedData::Models::Ontology.find(ont.id).first.latest_submission
        rescue
          @logger.error("Unable to retrieve latest submission for #{ont.id.to_s} in Recommender.")
        end
        return 0 if sub.nil?
        begin
          sub.bring(metrics: LinkedData::Models::Metric.attributes)
          cls_count = sub.metrics.classes
        rescue
          @logger.error("Unable to retrieve metrics for latest submission of #{ont.id.to_s} in Recommender.")
          cls_count = LinkedData::Models::Class.where.in(sub).count
        end
        return cls_count || 0
      end


    end

  end
end
