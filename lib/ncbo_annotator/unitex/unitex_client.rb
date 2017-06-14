require 'socket'

require 'ncbo_annotator/unitex/unitex_annotated_text'

module Annotator
  module Unitex
    class Client
      def initialize(host, port, alt_host, alt_port, logger=nil)
        @socket = nil
        @logger = logger ||= Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)
        hosts = [host, alt_host]
        ports = [port, alt_port]
        use_ind = [0, 1].sample
        alt_ind = use_ind == 0 ? 1 : 0

        begin
          @socket = TCPSocket.open(hosts[use_ind], ports[use_ind].to_i)
        rescue Exception => e
          @logger.error("Can't connect to unitex host #{hosts[use_ind]}:#{ports[use_ind]}: #{e.class}: #{e.message}. Now trying #{hosts[alt_ind]}:#{ports[alt_ind]}...")
          begin
            @socket = TCPSocket.open(hosts[alt_ind], ports[alt_ind].to_i)
          rescue Exception => e1
            # try one final time, though we really shouldn't be here
            # one of the servers should always be up
            begin
              @socket = TCPSocket.open(hosts[use_ind], ports[use_ind].to_i)
            rescue Exception => e2
              raise StandardError, "Unable to establish unitex connection to #{hosts[use_ind]}:#{ports[use_ind]} or #{hosts[alt_ind]}:#{ports[alt_ind]} due to exception #{e2.class}: #{e2.message}\n#{e2.backtrace.join("\n\t")}"
            end
          end
        end
      end

      def close()
        @socket.close
      end
      
      def annotate(text, longword, replace=true)
        begin
          text = text.upcase.gsub("\n", " ")
        rescue ArgumentError => e
          # NCBO-1230 - Annotation failure after repeated calls
          text = text.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
          text = text.gsub("\n", " ")
        end

        if text.strip.length == 0
          return Annotator::Unitex::AnnotatedText(text, [])
        end
        message = self.message(text, longword, replace)
        @socket.send(message, 0)
        annotations = []
        line = "init"


        current_response = @socket.gets
        response = ''
        while current_response !=nil
          response+=current_response
          current_response = @socket.gets
        end

        lines = response.split("\n")

        for line in lines
          if line and line.strip.length > 0
            ann = line.split("\t")
            if ann.length >1
              annotations << ann
            end
          end
        end

        # while line != nil and line.length > 0 do
        #   line = self.get_line
        #   if line and line.strip.length > 0
        #     ann = line.split("\t")
        #     if ann.length > 1
        #       annotations << ann
        #     end
        #   end
        # end
        Annotator::Unitex::AnnotatedText.new(text, annotations)
      end

      def message(text, longword, replace=true)
        flags = "A"
        flags += longword ? "Y" : "N"
        flags += replace ? "Y" : "N"
        message = flags + " " +text + "\n"
        message.encode("utf-8")
      end

    end
  end
end
