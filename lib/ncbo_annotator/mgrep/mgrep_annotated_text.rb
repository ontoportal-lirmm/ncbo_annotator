module Annotator
  module Mgrep

    @annotation_struct = Struct.new(:offset_from, :offset_to, :string_id, :value)
    def self.annotation_struct
      return @annotation_struct
    end

    class AnnotatedText < Array
        def initialize(text,annotations)
          @text = text
          @annotations = annotations
        end

        def length
          return @annotations.length
        end

        def get(i)
          raise ArgumentError, "Annotation index off range" unless i < self.length 

          a = @annotations[i]
          ofrom = a[1].to_i
          oto = a[2].to_i
          value  = @text[ofrom-1..oto-1]
          return Mgrep.annotation_struct.new(ofrom,oto,a[0],value)
        end

        def each
          cursor = 0
          raise ArgumentError, "No block given" unless block_given?
          vars = nil
          while cursor < self.length do
            yield self.get(cursor)
            cursor = cursor + 1
          end
        end

        def filter_min_size(min_length)
          filtered_anns = @annotations.select {|a| a[2].to_i - a[1].to_i + 1 > min_length }
          @annotations = filtered_anns
        end
    end
  end
end
