require 'socket'

module Annotator
  module Mgrep
    class Client
      def initialize(host, port, alt_host, alt_port)
        hosts = [host, alt_host]
        ports = [port, alt_port]
        use_ind = [0, 1].sample
        alt_ind = use_ind == 0 ? 1 : 0
        @socket = nil

        begin
          @socket = TCPSocket.open(hosts[use_ind], ports[use_ind].to_i)
        rescue Errno::ECONNREFUSED
          begin
            @socket = TCPSocket.open(hosts[alt_ind], ports[alt_ind].to_i)
          rescue Exception
            # try one final time, though we really shouldn't be here
            # one of the servers should always be up
            begin
              @socket = TCPSocket.open(hosts[use_ind], ports[use_ind].to_i)
            rescue Exception => e
              raise StandardError, "Unable to establish mgrep connection due to exception #{e.class}: #{e.message}\n#{e.backtrace.join("\n\t")}"
            end
          end
        end

        self.annotate("init", true, true)
      end

      def close()
        @socket.close()
      end
      
      def annotate(text, longword, wholeword=true)
        begin
          text = text.upcase.gsub("\n", " ")
        rescue ArgumentError => e
          # NCBO-1230 - Annotation failure after repeated calls
          text = text.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
          text = text.upcase.gsub("\n", " ")
        end

        if text.strip().length == 0
          return AnnotatedText(text, [])
        end
        message = self.message(text, longword, wholeword)
        @socket.send(message, 0)
        annotations = []
        line = "init"
        while line.length > 0 do
          line = self.get_line()
          if line and line.strip().length > 0
            ann = line.split("\t") 
            if ann.length > 1
              annotations << ann
            end
          end
        end
        return AnnotatedText.new(text, annotations)
      end

      def message(text, longword, wholeword)
        flags = "A"
        flags += longword ? "Y" : "N" 
        flags += wholeword ? "Y" : "N" 
        message = flags + text + "\n"
        return message.encode("utf-8")
      end

      def get_line()
        cont = true
        res = []
        while cont do
          data = @socket.recv(1)
          if data == "\n"
            return res.join("")
          end
          res << data
        end
        return nil
      end

    end
  end
end
