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

  # Sends requests through a FHIR::Client and hands back the raw response along with the parsed
  # resource, as asserts check status codes and headers, and resources are kept as plain Hashes
  # for FHIRPath. Every FHIR::ClientReply is also passed to `on_reply` (e.g. to record requests)
  class Client
    JSON_FORMAT = FHIR::Formats::ResourceFormat::RESOURCE_JSON

    # A client of its own, sending `authorization` as is in the Authorization header
    def self.build(base_url, authorization: nil)
      raise Error, "FHIR server base URL is not set" if base_url.nil? || base_url.empty?

      fhir_client = FHIR::Client.new(base_url)
      fhir_client.additional_headers = { "Authorization" => authorization } if authorization
      new(fhir_client)
    end

    def initialize(fhir_client, &on_reply)
      @fhir_client = fhir_client
      @on_reply = on_reply
    end

    def execute(path, method: "get", data: nil, params: {})
      path = "#{path}?#{URI.encode_www_form(params)}" unless params.empty?
      # fhir_headers carries the client's additional headers, which its raw HTTP methods skip
      headers = @fhir_client.fhir_headers.merge("Accept" => JSON_FORMAT)
      reply = request(method.to_s.downcase, path, data, headers)
      @on_reply&.call(reply)
      response = Response.new(reply.code.to_i, Headers.new(reply.response[:headers]), reply.response[:body])
      [response, parse_resource(response)]
    end

    private

    # FHIR::Client keeps its raw HTTP methods private
    def request(method, path, data, headers)
      case method
      when "get", "delete" then @fhir_client.send(method, path, headers)
      when "post", "put" then @fhir_client.send(method, path, data, headers.merge("Content-Type" => JSON_FORMAT))
      else raise Error, "HTTP method '#{method}' is not supported"
      end
    end

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
