require 'socket'

module Annotator
  module Mgrep
    class Client
      def initialize(host,port)
        @host=host
        @port=port
        @socket = TCPSocket.open(@host,@port.to_i)
        self.annotate("init",true,true)
      end

      def close()
        @socket.close()
      end
      
      def annotate(text,longword,wholeword=true)
        text = text.upcase.gsub("\n"," ")
        if text.strip().length == 0
          return  AnnotatedText(text, [])
        end
        message = self.message(text,longword,wholeword)
        @socket.send(message,0)
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

      def message(text,longword,wholeword)
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
