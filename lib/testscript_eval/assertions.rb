# frozen_string_literal: true

require "jsonpath"

module TestscriptEval
  module Assertions
    # What an assert can see besides the last operation's response
    Context = Struct.new(:variables, :fixtures, :responses, :validator, :profiles, keyword_init: true)

    # http://hl7.org/fhir/assert-response-code-types, and `badRequest`, which scripts use for `bad`
    RESPONSE_CODES = {
      "continue" => 100, "switchingProtocols" => 101, "okay" => 200, "created" => 201, "accepted" => 202,
      "nonAuthoritativeInformation" => 203, "noContent" => 204, "resetContent" => 205, "partialContent" => 206,
      "multipleChoices" => 300, "movedPermanently" => 301, "found" => 302, "seeOther" => 303,
      "notModified" => 304, "useProxy" => 305, "temporaryRedirect" => 307, "permanentRedirect" => 308,
      "bad" => 400, "badRequest" => 400, "unauthorized" => 401, "paymentRequired" => 402, "forbidden" => 403,
      "notFound" => 404, "methodNotAllowed" => 405, "notAcceptable" => 406,
      "proxyAuthenticationRequired" => 407, "requestTimeout" => 408, "conflict" => 409, "gone" => 410,
      "lengthRequired" => 411, "preconditionFailed" => 412, "contentTooLarge" => 413, "uriTooLong" => 414,
      "unsupportedMediaType" => 415, "rangeNotSatisfiable" => 416, "expectationFailed" => 417,
      "misdirectedRequest" => 421, "unprocessableContent" => 422, "unprocessable" => 422,
      "upgradeRequired" => 426, "internalServerError" => 500, "notImplemented" => 501, "badGateway" => 502,
      "serviceUnavailable" => 503, "gatewayTimeout" => 504, "httpVersionNotSupported" => 505
    }.freeze

    module_function

    def check(condition, message)
      Operations.check(condition, message)
    end

    def not_implemented(assert_name, _assertion, _response, _resource, _context)
      raise NotImplementedAssert, "Assert rule #{assert_name} is not implemented"
    end

    def request?(assertion)
      assertion["direction"] == "request"
    end

    # The request's headers for `direction: request`, the response's otherwise
    def header_field(_assert_name, assertion, response, _resource, context)
      headers = request?(assertion) ? response.request&.headers : response.headers
      value = assertion["value"]
      value = parse_variable_in_string(value, context.variables) if value.is_a?(String)
      Operations.run(assertion.fetch("operator", "equals"), headers&.[](assertion["headerField"]), value)
    end

    def request_url(_assert_name, assertion, response, _resource, context)
      expected = parse_variable_in_string(assertion["requestURL"], context.variables)
      Operations.run(assertion.fetch("operator", "equals"), response.request&.url, expected)
    end

    def request_method(_assert_name, assertion, response, _resource, _context)
      Operations.run(assertion.fetch("operator", "equals"), response.request&.method, assertion["requestMethod"].downcase)
    end

    def response_code(_assert_name, assertion, response, _resource, _context)
      Operations.run(assertion.fetch("operator", "equals"), response.status.to_s, assertion["responseCode"])
    end

    def resource(_assert_name, assertion, _response, resource, _context)
      resource_type = assertion["resource"]
      check(resource.is_a?(Hash), "No resource in the response")
      check(resource_type == resource["resourceType"],
            "Expected resource #{resource_type}, got #{resource["resourceType"]}")
    end

    def path(_assert_name, assertion, _response, resource, context)
      path = Misc.resolve_string_template(assertion["path"], context.variables)
      TestscriptEval.logger.debug("Parse #{path}")
      value = assertion["value"]
      value = parse_variable_in_string(value, context.variables) if value.is_a?(String)
      Operations.run(assertion.fetch("operator", value.nil? ? "exists" : "equals"), Misc.path(resource, path), value)
    end

    def response(_assert_name, assertion, response, _resource, _context)
      expected = assertion["response"]
      status = RESPONSE_CODES.fetch(expected) { raise Error, "Response code #{expected} is not supported" }
      operator = assertion.fetch("operator", "equals")
      operator = "equals" unless %w[equals notEquals].include?(operator)
      Operations.run(operator, response.status, status)
    rescue AssertionFailed
      raise AssertionFailed, "Expected status #{operator == "notEquals" ? "other than " : ""}#{status} " \
                             "(#{expected}), got #{response.status}"
    end

    def compare_to_source_path(_assert_name, assertion, _response, resource, context)
      fixture = context.fixtures.fetch(assertion["compareToSourceId"])
      expected = Operations.scalar(Misc.path(fixture, assertion["compareToSourcePath"]))
      Operations.run(assertion.fetch("operator", "equals"), Misc.path(resource, assertion["path"]), expected)
    end

    def compare_to_source_expression(_assert_name, assertion, _response, resource, context)
      fixture = context.fixtures.fetch(assertion["compareToSourceId"])
      source_expression = expression_with_variables(assertion["compareToSourceExpression"], context)
      expected = Misc.evaluate(fixture, source_expression)
      # Without an expression of its own, the response is read with the source expression
      actual = Misc.evaluate(resource, assertion.key?("expression") ? expression_with_variables(assertion["expression"], context) : source_expression)
      operator = assertion.fetch("operator", "equals")
      # Both are collections: equals compares them as a whole
      return check(actual == expected, "Got #{actual.inspect}, expected #{expected.inspect}") if operator == "equals"

      Operations.run(operator, actual, expected.length == 1 ? expected.first : expected)
    end

    def compare_response_expression_to_value(_assert_name, assertion, _response, resource, context)
      # a path with a value is compared by the "path" rule
      return unless assertion.key?("expression")

      expression = Misc.expression_of(assertion["expression"])
      result = Misc.evaluate(resource, expression_with_variables(assertion["expression"], context))
      check(!result.empty?, "Expression '#{expression}' returned no value")
      TestscriptEval.logger.warn("Expression '#{expression}' returns more than one value") if result.length > 1
      value = assertion["value"]
      value = parse_variable_in_string(value, context.variables) if value.is_a?(String)
      Operations.run(assertion.fetch("operator", "equals"), result.first, value)
    end

    # An assert expression with its ${variables} resolved (a String, or an Expression Hash)
    def expression_with_variables(expression, context)
      return parse_variable_in_string(expression, context.variables) if expression.is_a?(String)
      return expression unless expression.is_a?(Hash) && expression["expression"].is_a?(String)

      expression.merge("expression" => parse_variable_in_string(expression["expression"], context.variables))
    end

    def parse_variable_in_string(string, variables)
      string.gsub(/\$\{([\w-]+)\}/) { variables.fetch(Regexp.last_match(1)).to_s }
    end

    def expression(_assert_name, assertion, _response, resource, context)
      # An expression with a value is compared by the "value" rule, and one with
      # compareToSourceId by the "compareToSourceExpression" rule
      return if assertion.key?("value") || assertion.key?("compareToSourceId") || assertion.key?("path")

      # Without a value the expression is a boolean condition: operator "eval",
      # which is also the default (https://hl7.org/fhir/R5/testing.html#assertion-table)
      operator = assertion.fetch("operator", "eval")
      raise NotImplementedAssert, "Operator #{operator} without a value is not implemented" if operator != "eval"

      Operations.run(operator, Misc.evaluate(resource, expression_with_variables(assertion["expression"], context)), nil)
    end

    def minimum_id(_assert_name, assertion, _response, resource, context)
      id = assertion["minimumId"]
      fixture = context.fixtures.fetch(id)
      check(resource.is_a?(Hash), "No resource in the response")
      fixture.each do |key, value|
        check(resource.key?(key) && resource[key] == value, "minimumId #{id}: #{key} does not match")
      end
    end

    # `json`/`xml` (TestScript formats) match any JSON/XML MIME type, e.g. application/fhir+json;charset=utf-8
    def content_type(_assert_name, assertion, response, _resource, _context)
      headers = request?(assertion) ? response.request&.headers : response.headers
      actual = headers&.[]("Content-Type")
      expected = assertion["contentType"]
      if %w[json xml].include?(expected.downcase) && assertion.fetch("operator", "equals") == "equals"
        return check(actual.to_s.downcase.include?(expected.downcase), "Content-Type #{actual.inspect} is not #{expected}")
      end

      Operations.run(assertion.fetch("operator", "equals"), actual&.split(";")&.first, expected)
    end

    def navigation_links(_assert_name, _assertion, _response, resource, _context)
      check(resource.is_a?(Hash), "No resource in the response")
      check(resource.key?("link"), "Response has no navigation links")
    end

    def validate_profile_id(_assert_name, assertion, _response, resource, context)
      profile_url = resolve_profile(assertion["validateProfileId"], context.profiles)
      check(resource.is_a?(Hash) && resource.key?("resourceType"), "No resource to validate against #{profile_url}")
      errors = context.validator.call(resource, profile_url)
      check(errors.empty?, "Validation against #{profile_url} failed:\n#{errors.join("\n")}")
    end

    # validateProfileId is the id of a TestScript.profile entry; a canonical URL given
    # directly instead (as fhir-frog TestScripts do) is used as is
    # (R5 has TestScript.profile as a list of canonical URLs)
    def resolve_profile(profile_id, profiles)
      profile = profiles.find { |p| p.is_a?(Hash) && p["id"] == profile_id }
      return profile["reference"] if profile
      return profile_id if profile_id.include?("/")

      raise Error, "validateProfileId '#{profile_id}' does not match any TestScript.profile id"
    end

    # What an assert rule checked, for its failure message, e.g.
    # "Expression `issue.count() > 0` on the response"
    def checked(assert_name, assertion, context)
      source = assertion["sourceId"] ? "fixture/response #{assertion["sourceId"]}" : "the response"
      direction = request?(assertion) ? "Request" : "Response"
      case assert_name
      when "expression", "value"
        return unless assertion.key?("expression")
        return if assert_name == "expression" && (assertion.key?("value") || assertion.key?("compareToSourceId"))

        "Expression `#{expression_text(assertion["expression"], context)}` on #{source}"
      when "compareToSourceExpression"
        actual = expression_text(assertion.fetch("expression", assertion["compareToSourceExpression"]), context)
        "Expression `#{actual}` on #{source} compared to " \
          "`#{expression_text(assertion["compareToSourceExpression"], context)}` on #{assertion["compareToSourceId"]}"
      when "path"
        "Path `#{Misc.resolve_string_template(assertion["path"], context.variables)}` on #{source}"
      when "compareToSourcePath"
        "Path `#{assertion["path"]}` on #{source} compared to `#{assertion["compareToSourcePath"]}` " \
          "on #{assertion["compareToSourceId"]}"
      when "headerField" then "#{direction} header #{assertion["headerField"]}"
      when "contentType" then "#{direction} Content-Type"
      when "response", "responseCode" then "Response status (operator #{assertion.fetch("operator", "equals")})"
      when "requestURL" then "Request URL"
      when "requestMethod" then "Request method"
      when "resource" then "Resource type"
      end
    end

    def expression_text(expression, context)
      Misc.expression_of(expression_with_variables(expression, context))
    rescue Error
      Misc.expression_of(expression)
    end

    RULES = {
      "headerField" => :header_field,
      "responseCode" => :response_code,
      "resource" => :resource,
      "path" => :path,
      "expression" => :expression,
      "response" => :response,
      "compareToSourceExpression" => :compare_to_source_expression,
      "minimumId" => :minimum_id,
      "contentType" => :content_type,
      "navigationLinks" => :navigation_links,
      "compareToSourcePath" => :compare_to_source_path,
      "requestURL" => :request_url,
      "requestMethod" => :request_method,
      "value" => :compare_response_expression_to_value,
      "validateProfileId" => :validate_profile_id
    }.freeze

    # Runs every rule the assert has. Returns a warning message when a warningOnly assert
    # fails, nil otherwise
    # `sourceId` points the assert at a fixture, or the response of the operation with that responseId
    def evaluate(assertion, response, resource, context)
      TestscriptEval.logger.info(assertion["description"])
      if assertion.key?("sourceId")
        source_id = assertion["sourceId"]
        response = context.responses.fetch(source_id, response)
        resource = context.fixtures.fetch(source_id) { raise Error, "No fixture or response '#{source_id}'" }
      end

      RULES.each do |assert_name, rule|
        next unless assertion.key?(assert_name)

        begin
          send(rule, assert_name, assertion, response, resource, context)
        rescue AssertionFailed => e
          # say what was checked: the description alone often does not
          checked = checked(assert_name, assertion, context)
          raise e.class, checked ? "#{checked}: #{e.message}" : e.message
        end
      end
      nil
    rescue AssertionFailed => e
      message = "#{assertion["description"]}: #{e.message}"
      raise AssertionFailed, message unless assertion.fetch("warningOnly", false)

      TestscriptEval.logger.warn("warningOnly assert failed: #{message}")
      message
    end
  end
end
