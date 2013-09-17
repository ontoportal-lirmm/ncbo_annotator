require 'ontologies_linked_data'
require_relative 'recommendation'

module Recommender
  module Models

    class NcboRecommender

      DEFAULT_HIERARCHY_LEVELS = 5

      def recommend(text, ontologies=[])
        annotator = Annotator::Models::NcboAnnotator.new
        annotations = annotator.annotate(text, ontologies, [], false, DEFAULT_HIERARCHY_LEVELS)
        recommendations = {}
        termsMatched = []

        annotations.each do |ann|
          classId = ann.annotatedClass.id.to_s
          ontologyId = ann.annotatedClass.submission.ontology.id.to_s

          unless recommendations.include?(ontologyId)
            recommendations[ontologyId] = Recommendation.new
            recommendations[ontologyId].ontology = ann.annotatedClass.submission.ontology

            #TODO: there appears to be a bug that does not allow retrieving submission by its id because the id is incorrect. The workaround is to get the ontology object and then retrieve its latest submission.
            sub = LinkedData::Models::Ontology.find(ann.annotatedClass.submission.ontology.id).first.latest_submission

            unless (sub.nil?)
              sub.bring(metrics: LinkedData::Models::Metric.attributes)
              nclasses = nil

              if sub.metrics.nil?
                nclasses = LinkedData::Models::Class.where.in(sub).count
              else
                nclasses = sub.metrics.classes
              end
              recommendations[ontologyId].numTermsTotal = nclasses
            end
          end

          rec = recommendations[ontologyId]

          termsMatchedKey = "#{classId}_#{ontologyId}"

          unless termsMatched.include?(termsMatchedKey)
            termsMatched << termsMatchedKey
            rec.numTermsMatched += 1
          end

          rec.increment_score(ann)
        end

        vals = recommendations.values.sort {|a, b| b.score <=> a.score}

        return vals
      end

    end

  end
end
