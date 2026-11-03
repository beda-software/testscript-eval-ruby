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

  # What was sent, for `direction: request` asserts and requestURL/requestMethod
  Request = Struct.new(:method, :url, :headers)

  Response = Struct.new(:status, :headers, :body, :request)

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
  #
  # Bodies are sent and accepted as JSON, or as XML when an operation asks for it. Servers that
  # only speak JSON (e.g. Aidbox, which ignores XML bodies) can turn XML off with `xml: false`:
  # requests for XML then go out as JSON
  class Client
    JSON_FORMAT = FHIR::Formats::ResourceFormat::RESOURCE_JSON
    XML_FORMAT = FHIR::Formats::ResourceFormat::RESOURCE_XML

    # A request body FHIR::Client serializes by its Content-Type
    Payload = Struct.new(:resource) do
      # A String (e.g. the content of a Binary) is sent as is
      def to_json(*)
        resource.is_a?(String) ? resource : JSON.generate(resource)
      end

      def to_xml
        resource.is_a?(String) ? resource : FHIR::Json.from_json(JSON.generate(resource)).to_xml
      end
    end

    # A client of its own, sending `authorization` as is in the Authorization header
    def self.build(base_url, authorization: nil, xml: true)
      raise Error, "FHIR server base URL is not set" if base_url.nil? || base_url.empty?

      fhir_client = FHIR::Client.new(base_url)
      fhir_client.additional_headers = { "Authorization" => authorization } if authorization
      new(fhir_client, xml:)
    end

    def initialize(fhir_client, xml: true, &on_reply)
      @fhir_client = fhir_client
      @xml = xml
      @on_reply = on_reply
    end

    # `accept` and `content_type` are TestScript formats ("json", "xml") or MIME types
    def execute(path, method: "get", data: nil, params: {}, headers: {}, accept: nil, content_type: nil)
      path = "#{path}#{path.include?("?") ? "&" : "?"}#{URI.encode_www_form(params)}" unless params.empty?
      # fhir_headers carries the client's additional headers, which its raw HTTP methods skip
      headers = @fhir_client.fhir_headers.merge("Accept" => mime_type(accept)).merge(headers)
      # a String body keeps its own content type, even XML when XML is off
      headers["Content-Type"] = data.is_a?(String) && content_type ? content_type : mime_type(content_type) if data
      method = method.to_s.downcase
      reply = request(method, path, data, headers)
      @on_reply&.call(reply)
      request = Request.new(method, reply.request[:url].to_s, Headers.new(headers))
      response = Response.new(reply.code.to_i, Headers.new(reply.response[:headers]), reply.response[:body], request)
      [response, parse_resource(response)]
    end

    private

    def mime_type(format)
      return JSON_FORMAT if format.nil? || format.to_s.empty?

      xml = format.to_s.downcase.include?("xml")
      return XML_FORMAT if xml && @xml
      return JSON_FORMAT if xml || format.to_s.casecmp?("json")

      format
    end

    # FHIR::Client keeps its raw HTTP methods private
    def request(method, path, data, headers)
      case method
      when "get", "delete" then @fhir_client.send(method, path, headers)
      when "head" then @fhir_client.send(:head, path, headers)
      when "post", "put" then @fhir_client.send(method, path, data && Payload.new(data), headers)
      when "patch" then @fhir_client.send(:patch, path, data, headers)
      else raise Error, "HTTP method '#{method}' is not supported"
      end
    end

    # A 2xx body is the resource. Other statuses keep a FHIR resource body (e.g. the
    # OperationOutcome of a 422, which asserts check), anything else is wrapped in an ErrorBody
    def parse_resource(response)
      body = response.body
      return nil if body.nil? || body.strip.empty?

      resource = parse_body(body, response.headers["Content-Type"])
      return resource if (200..299).cover?(response.status) || (resource.is_a?(Hash) && resource["resourceType"])

      [404, 410].include?(response.status) ? ResourceNotFound.new(body) : OperationOutcome.new(body)
    end

    def parse_body(body, content_type)
      return TestscriptEval.parse_xml(body) if content_type.to_s.include?("xml") || body.lstrip.start_with?("<")

      JSON.parse(body)
    rescue JSON::ParserError, Nokogiri::XML::SyntaxError
      nil
    end
  end
end
