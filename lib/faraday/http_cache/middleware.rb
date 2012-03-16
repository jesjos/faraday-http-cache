require 'active_support/core_ext/hash/slice'

module Faraday
  module HttpCache
    # Public: The Middleware responsible for caching and serving responses.
    # The Middleware use the provided configuration options to establish a
    # 'Faraday::HttpCache::Storage' to cache responses retrieved by the stack
    # adapter. If a stored response can be served again for a subsequent
    # request, the Middleware will return the response instead of issuing a new
    # request to it's server. This Middleware should be the last attached handler
    # to your stack, so it will be closest to the inner app, avoiding issues
    # with other middlewares on your stack.
    #
    # Examples:
    #
    #   # Using the Middleware with a simple client:
    #   client = Faraday.new do |builder|
    #     builder.user :http_cache
    #     builder.adapter Faraday.default_adapter
    #   end
    #
    #   # Attach a Logger to the Middleware.
    #   client = Faraday.new do |builder|
    #     builder.use :http_cache, :logger => my_logger_instance
    #     builder.adapter Faraday.default_adapter
    #   end
    #
    #   # Provide an existing CacheStore (for instance, from a Rails app)
    #   client = Faraday.new do |builder|
    #     builder.use :http_cache, Rails.cache
    #   end
    class Middleware < Faraday::Middleware

      # Public: Initializes a new Middleware.
      #
      # app - the next endpoint on the 'Faraday' stack.
      # arguments - aditional options to setup the logger and the storage.
      #
      # Examples:
      #
      #   # Initialize the Middleware with a logger.
      #   Middleware.new(app, :logger => my_logger)
      #
      #   # Initialize the Middleware with a FileStore at the 'tmp' dir.
      #   Middleware.new(app, :file_store, 'tmp')
      def initialize(app, *arguments)
        super(app)

        if arguments.last.is_a? Hash
          options = arguments.pop
          @logger = options.delete(:logger)
        else
          options = arguments
        end

        store = arguments.shift

        @storage = Storage.new(store, options)
      end

      # Internal: Process the stack request to try to serve a cache response.
      # On a cacheable request, the Middleware will attempt to locate a
      # valid stored response to serve. On a cache miss, the Middleware will
      # forward the request and try to store the response for future requests.
      # If the request can't be cached, the request will be delegated directly
      # to the underlying app and does nothing to the response.
      # The processed steps will be recorded to be logged once the whole
      # process is finished.
      #
      # Returns a 'Faraday::Response' instance.
      def call(env)
        @trace = []
        @request = create_request(env)

        response = nil

        if can_cache?(@request[:method])
          response = call!(env)
        else
          trace :unacceptable
          response = @app.call(env)
        end

        log_request
        response
      end

      private

      # Internal: Validates if the current request method is valid for caching.
      #
      # Returns true if the method is ':get' or ':head'.
      def can_cache?(method)
        method == :get || method == :head
      end

      # Internal: Tries to located a valid response or forwards the call to the stack.
      # * If no entry is present on the storage, the 'fetch' method will forward
      # the call to the remaining stack and return the new response.
      # * If a fresh response is found, the Middleware will abort the remaining
      # stack calls and return the stored response back to the client.
      # * If a response is found but isn't fresh anymore, the Middleware will
      # revalidate the response back to the server.
      #
      # env - the environment 'Hash' provided from the 'Faraday' stack.
      #
      # Returns the actual 'Faraday::Response' instance to be served.
      def call!(env)
        entry = @storage.read(@request)

        return fetch(env) if entry.nil?

        if entry.fresh?
          response = entry
          trace :fresh
        else
          response = validate(entry, env)
        end

        response.to_response
      end

      # Internal: Tries to validated a stored entry back to it's origin server
      # using the 'If-Modified-Since' and 'If-None-Match' headers with the
      # existing 'Last-Modified' and 'ETag' headers. If the new response
      # is marked as 'Not Modified', the previous stored response will be used
      # and forwarded against the Faraday stack. Otherwise, the freshly new
      # response will be stored (replacing the old one) and used.
      #
      # entry - a stale 'Faraday::HttpCache::Response' retrieved from the cache.
      # env - the environment 'Hash' to perform the request.
      #
      # Returns the 'Faraday::HttpCache::Response' to be forwarded into the stack.
      def validate(entry, env)
        headers = env[:request_headers]
        headers['If-Modified-Since'] = entry.last_modified
        headers['If-None-Match'] = entry.etag
        response = Response.new(@app.call(env).marshal_dump)

        if response.not_modified?
          trace :valid
          response = entry
        end

        store(response)
        response
      end

      # Internal: Records a traced action to be used by the logger once the
      # request/response phase is finished.
      #
      # operation - the name of the performed action, a String or Symbol.
      #
      # Returns nothing.
      def trace(operation)
        @trace << operation
      end

      # Internal: Stores the response into the storage.
      # If the response isn't cacheable, a trace action 'invalid' will be
      # recorded for logging purposes.
      #
      # response - a 'Faraday::HttpCache::Response' instance to be stored.
      #
      # Returns nothing.
      def store(response)
        if response.cacheable?
          trace :store
          @storage.write(@request, response)
        else
          trace :invalid
        end
      end

      # Internal: Fetches the response from the Faraday stack and stores it.
      #
      # env - the environment 'Hash' from the Faraday stack.
      #
      # Returns the fresh 'Faraday::Response' instance.
      def fetch(env)
        response = Response.new(@app.call(env).marshal_dump)
        trace :miss
        store(response)
        response.to_response
      end

      # Internal: Creates a new 'Hash' containing the request information.
      #
      # env - the environment 'Hash' from the Faraday stack.
      #
      # Returns a 'Hash' containing the ':method', ':url' and 'request_headers'
      # entries.
      def create_request(env)
        @request = env.slice(:method, :url)
        @request[:request_headers] = env[:request_headers].dup
        @request
      end

      # Internal: Logs the trace info about the incoming request
      # and how the middleware handled it.
      # This method does nothing if theresn't a logger present.
      #
      # Returns nothing.
      def log_request
        return unless @logger

        method = @request[:method].to_s.upcase
        path = @request[:url].path
        line = "HTTP Cache: [#{method} #{path}] #{@trace.join(', ')}"
        @logger.debug(line)
      end
    end
  end
end
