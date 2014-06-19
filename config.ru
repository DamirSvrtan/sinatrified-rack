require 'rack'
class Stream
  def self.schedule(*) yield end
  def self.defer(*)    yield end

  def initialize(scheduler = self.class, keep_open = false, &back)
    @back, @scheduler, @keep_open = back.to_proc, scheduler, keep_open
    @callbacks, @closed = [], false
  end

  def close
    return if @closed
    @closed = true
    @scheduler.schedule { @callbacks.each { |c| c.call }}
  end

  def each(&front)
    @front = front
    @scheduler.defer do
      begin
        @back.call(self)
      rescue Exception => e
        @scheduler.schedule { raise e }
      end
      close unless @keep_open
    end
  end

  def <<(data)
    @scheduler.schedule { @front.call(data.to_s) }
    self
  end

  def callback(&block)
    return yield if @closed
    @callbacks << block
  end

  alias errback callback

  def closed?
    @closed
  end
end

class ExtendedRack
  attr_reader :app
  def initialize(app)
    @app = app
  end

  def call(env)
    result, callback = app.call(env), env['async.callback']
    return result unless callback and async?(*result)
    after_response { callback.call result }
    setup_close(env, *result)
    throw :async
  end

  private

    def setup_close(env, status, headers, body)
      return unless body.respond_to? :close and env.include? 'async.close'
      env['async.close'].callback { body.close }
      env['async.close'].errback { body.close }
    end

    def after_response(&block)
      raise NotImplementedError, "only supports EventMachine at the moment" unless defined? EventMachine
      EventMachine.next_tick(&block)
    end

    def async?(status, headers, body)
      return true if status == -1
      body.respond_to? :callback and body.respond_to? :errback
    end
end

class MyStreamApp

  attr_reader :env

  def call(env)
    @env = env
    @params = {}
    stream do |out|
      out << "It's gonna be legen -\n"
      sleep 0.5
      out << " (wait for it) \n"
      sleep 1
      out << "- dary!\n"
    end
  end

  def stream(keep_open = false)
    scheduler = env['async.callback'] ? EventMachine : Stream
    current   = @params.dup
    [200, {'Content-Type' => 'text/event-stream'}, Stream.new(scheduler, keep_open) { |out| with_params(current) { yield(out) }}]
  end

  def with_params(temp_params)
    original, @params = @params, temp_params
    yield
  ensure
    @params = original if original
  end

end

use ExtendedRack
run MyStreamApp.new