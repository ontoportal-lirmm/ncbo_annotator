module Annotator
  module Mgrep

    @annotation_struct = Struct.new(:offset_from, :offset_to, :string_id, :value)
    def self.annotation_struct
      return @annotation_struct
    end

    class AnnotatedText
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
          filtered_anns = @annotations.select {|a| a[2].to_i - a[1].to_i + 1 >= min_length }
          @annotations = filtered_anns
        end

        def filter_integers()
          filtered_anns = @annotations.select {|a| !@text[a[1].to_i-1..a[2].to_i-1].numeric? }
          @annotations = filtered_anns
        end

        def filter_stop_words(stop_words)
          return if stop_words.nil?
          return if stop_words.length == 0
          filtered_anns = @annotations.select {|a| !stop_words.include?(a[-1]) }
          @annotations = filtered_anns
        end
    end
  end
end
