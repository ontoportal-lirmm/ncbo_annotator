#!/usr/bin/env ruby
# encoding: utf-8

require "bundler/setup"
require "bunny"
require "thread"



class RecognizerClient
  attr_reader :reply_queue
  attr_accessor :response, :call_id
  attr_reader :lock, :condition


  def initialize(host, port)
    conn = Bunny.new(:host => host, :port =>port,:automatically_recover => false)
    conn.start
    ch   = conn.create_channel
    @ch             = ch
    @exchange              = ch.default_exchange

    @server_queue   = "unitex"
    @reply_queue    = ch.queue("unitex_reply", :exclusive => true)

    @lock      = Mutex.new
    @condition = ConditionVariable.new
    that       = self

    @reply_queue.subscribe do |delivery_info, properties, payload|
      if properties[:correlation_id] == that.call_id
        that.response = payload.to_i
        that.lock.synchronize{that.condition.signal}
      end
    end
  end

  def call(text)
    self.call_id = self.generate_uuid

    @exchange.publish(text,
                      :routing_key    => @server_queue,
                      :correlation_id => call_id,
                      :reply_to       => @reply_queue.name)

    lock.synchronize{condition.wait(lock)}
    response
  end

  protected

  def generate_uuid
    # very naive but good enough for code
    # examples
    "#{rand}#{rand}#{rand}"
  end
end