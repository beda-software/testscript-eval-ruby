# frozen_string_literal: true

require "fhir_client"
require "uri"

module TestscriptEval
  # Response headers with case-insensitive lookup
  class Headers
    def initialize(headers)
      @headers = (headers || {}).to_h do |name, value|
        [normalize(name), value.is_a?(Array) ? value.join(", ") : value.to_s]
      end
    end

    def [](name)
      @headers[normalize(name)]
    end

    def to_h
      @headers.dup
    end

    private

    def normalize(name)
      name.to_s.downcase.tr("_", "-")
    end
  end

  Response = Struct.new(:status, :headers, :body)

  # The body of a non-2xx response, which is not a resource
  ErrorBody = Struct.new(:body) do
    def to_s
      body.to_s
    end
  end

  class ResourceNotFound < ErrorBody; end

  class OperationOutcome < ErrorBody; end

  # A FHIR client that hands back the raw response along with the parsed resource, as asserts
  # check status codes and headers, and resources are kept as plain Hashes for FHIRPath
  class Client < FHIR::Client
    JSON_FORMAT = FHIR::Formats::ResourceFormat::RESOURCE_JSON

    def initialize(base_url, authorization: nil)
      raise Error, "FHIR server base URL is not set" if base_url.nil? || base_url.empty?

      super(base_url)
      return unless authorization

      @security_headers = { "Authorization" => authorization }
      @use_basic_auth = true
    end

    def execute(path, method: "get", data: nil, params: {})
      path = "#{path}?#{URI.encode_www_form(params)}" unless params.empty?
      headers = { "Accept" => JSON_FORMAT }
      reply =
        case method.to_s.downcase
        when "get" then get(path, headers)
        when "delete" then delete(path, headers)
        when "post" then post(path, data, headers.merge("Content-Type" => JSON_FORMAT))
        when "put" then put(path, data, headers.merge("Content-Type" => JSON_FORMAT))
        else raise Error, "HTTP method '#{method}' is not supported"
        end
      response = Response.new(reply.code.to_i, Headers.new(reply.response[:headers]), reply.response[:body])
      [response, parse_resource(response)]
    end

    private

    def parse_resource(response)
      body = response.body
      if (200..299).cover?(response.status)
        body.nil? || body.empty? ? nil : JSON.parse(body)
      elsif [404, 410].include?(response.status)
        ResourceNotFound.new(body)
      else
        OperationOutcome.new(body)
      end
    end
  end
end
