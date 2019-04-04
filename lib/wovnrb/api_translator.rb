require 'addressable'
require 'digest'
require 'json'
require 'zlib'

module Wovnrb
  class ApiTranslator
    def initialize(store, headers)
      @store = store
      @headers = headers
    end

    def translate(body)
      connection = prepare_connection
      request = prepare_request(body)

      begin
        response = connection.request(request)
      rescue => e
        @headers.trace('API connection failure: ' + e.message)
        WovnLogger.error("\"#{e.message}\" error occurred when contacting WOVNio translation API")
        return body
      end
      @headers.trace('API connection established')

      if response && @headers.debug_mode?
        @headers.register_custom_http_header('X-Wovn-Cache', response['x-cache'])
        @headers.register_custom_http_header('X-Wovn-Cache-Hits', response['x-cache-hits'])
        @headers.register_custom_http_header('X-Wovn-Surrogate-Key', response['x-wovn-surrogate-key'])
      end

      case response
      when Net::HTTPSuccess
        @headers.trace('API response successful: status ' + response.code)
        if response.header['Content-Encoding'] == 'gzip'
          response_body = Zlib::GzipReader.new(StringIO.new(response.body)).read

          JSON.parse(response_body)['body'] || body
        elsif @store.dev_mode?
          JSON.parse(response.body)['body'] || body
        else
          @headers.trace('API response content-encoding invalid: ' + response.header['Content-Encoding'])
          WovnLogger.error("Received invalid content (\"#{response.header['Content-Encoding']}\") from WOVNio translation API.")
          body
        end
      else
        @headers.trace('API response unsuccessful: status ' + response.code)
        WovnLogger.error("Received \"#{response.message}\" from WOVNio translation API.")
        body
      end
    end

    private

    def prepare_connection
      connection = Net::HTTP.new(api_uri.host, api_uri.port)

      connection.open_timeout = api_timeout
      connection.read_timeout = api_timeout

      connection
    end

    def prepare_request(body)
      data = compress_request_data(generate_request_data(body))
      headers = {
        'Accept-Encoding' => 'gzip',
        'Content-Type' => 'application/octet-stream',
        'Content-Length' => data.bytesize.to_s
      }
      request = Net::HTTP::Post.new(generate_request_path(body), headers)

      request.body = data

      request
    end

    def generate_request_path(body)
      "#{api_uri.path.sub(/\/$/, '')}/translation?cache_key=#{generate_cache_key(body)}"
    end

    def generate_cache_key(body)
      cache_key_components = {
        'token' => token,
        'settings_hash' => settings_hash,
        'body_hash' => Digest::MD5.hexdigest(body),
        'path' => page_pathname,
        'lang' => lang_code
      }
      if @headers.disable_cache?
        cache_key_components.merge!(
          'disableCache' => Time.now.to_formatted_s(:number)
        )
      end
      cache_key_string = cache_key_components.map { |k, v| "#{k}=#{v}" }.join('&')

      CGI.escape("(#{cache_key_string})")
    end

    def generate_request_data(body)
      data = {
        'url' => page_url,
        'token' => token,
        'lang_code' => lang_code,
        'url_pattern' => url_pattern,
        'product' => 'WOVN.rb',
        'version' => VERSION,
        'body' => body
      }
      if @headers.debug_mode?
        data.merge!(
          'debug_mode' => 'true',
          'log_html' => 'true'
        )
      end

      data['custom_lang_aliases'] = JSON.dump(custom_lang_aliases) unless custom_lang_aliases.empty?

      data
    end

    def compress_request_data(data_hash)
      encoded_data_components = data_hash.map do |key, value|
        "#{key}=#{CGI.escape(value)}"
      end

      gzip = Zlib::GzipWriter.new(StringIO.new)
      gzip << encoded_data_components.join('&')
      gzip.close.string
    end

    def api_uri
      Addressable::URI.parse(@store.settings['api_url'])
    end

    def api_timeout
      @store.settings['api_timeout_seconds']
    end

    def settings_hash
      Digest::MD5.hexdigest(JSON.dump(@store.settings))
    end

    def token
      @store.settings['project_token']
    end

    def lang_code
      @headers.lang_code
    end

    def url_pattern
      @store.settings['url_pattern']
    end

    def custom_lang_aliases
      @store.settings['custom_lang_aliases']
    end

    def page_url
      "#{@headers.protocol}://#{@headers.url}"
    end

    def page_pathname
      @headers.pathname_with_trailing_slash_if_present
    end
  end
end