# frozen_string_literal: true

require "jsonpath"

module TestscriptEval
  module Assertions
    # What an assert can see besides the last operation's response
    Context = Struct.new(:variables, :fixtures, :validator, :profiles, keyword_init: true)

    RESPONSE_CODES = { "okay" => 200, "created" => 201, "bad" => 400, "notFound" => 404 }.freeze

    module_function

    def check(condition, message)
      Operations.check(condition, message)
    end

    def not_implemented(assert_name, _assertion, _response, _resource, _context)
      raise NotImplementedAssert, "Assert rule #{assert_name} is not implemented"
    end

    def header_field(_assert_name, assertion, response, _resource, _context)
      Operations.run(assertion.fetch("operator"), response.headers[assertion["headerField"]], assertion["value"])
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
      result = resource.is_a?(Hash) ? JsonPath.new(path).on(resource) : []
      Operations.run(assertion.fetch("operator", "exists"), result, assertion["value"])
    end

    def response(_assert_name, assertion, response, _resource, _context)
      expected = assertion["response"]
      status = RESPONSE_CODES.fetch(expected) { raise Error, "Response code #{expected} is not supported" }
      check(response.status == status, "Expected status #{status} (#{expected}), got #{response.status}")
    end

    def compare_to_source_expression(_assert_name, assertion, _response, resource, context)
      fixture = context.fixtures.fetch(assertion["compareToSourceId"])
      expected = Misc.fhirpath(fixture, assertion["compareToSourceExpression"])
      actual = Misc.fhirpath(resource, assertion["expression"])
      Operations.run(assertion.fetch("operator", "exists"), actual, expected)
    end

    def compare_response_expression_to_value(_assert_name, assertion, _response, resource, context)
      source = assertion["sourceId"] ? context.fixtures.fetch(assertion["sourceId"]) : resource
      expression = assertion["expression"]
      result = Misc.fhirpath(source, expression)
      check(!result.empty?, "Expression '#{expression}' returned no value")
      TestscriptEval.logger.warn("Expression '#{expression}' returns more than one value") if result.length > 1
      value = assertion["value"]
      value = parse_variable_in_string(value, context.variables) if value.is_a?(String)
      Operations.run(assertion.fetch("operator", "equals"), result.first, value)
    end

    def parse_variable_in_string(string, variables)
      string.gsub(/\$\{([\w-]+)\}/) { variables.fetch(Regexp.last_match(1)).to_s }
    end

    def expression(_assert_name, assertion, _response, resource, context)
      # An expression with a value is compared by the "value" rule, and one with
      # compareToSourceId by the "compareToSourceExpression" rule
      return if assertion.key?("value") || assertion.key?("compareToSourceId")

      # Without a value the expression is a boolean condition: operator "eval",
      # which is also the default (https://hl7.org/fhir/R5/testing.html#assertion-table)
      operator = assertion.fetch("operator", "eval")
      raise NotImplementedAssert, "Operator #{operator} without a value is not implemented" if operator != "eval"

      source = assertion["sourceId"] ? context.fixtures.fetch(assertion["sourceId"]) : resource
      Operations.run(operator, Misc.fhirpath(source, assertion["expression"]), nil)
    end

    def minimum_id(_assert_name, assertion, _response, resource, context)
      id = assertion["minimumId"]
      fixture = context.fixtures.fetch(id)
      check(resource.is_a?(Hash), "No resource in the response")
      fixture.each do |key, value|
        check(resource.key?(key) && resource[key] == value, "minimumId #{id}: #{key} does not match")
      end
    end

    def content_type(_assert_name, assertion, response, _resource, _context)
      Operations.run(assertion.fetch("operator", "equals"), response.headers["Content-Type"], assertion["contentType"])
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
    def resolve_profile(profile_id, profiles)
      profile = profiles.find { |p| p["id"] == profile_id }
      return profile["reference"] if profile
      return profile_id if profile_id.include?("/")

      raise Error, "validateProfileId '#{profile_id}' does not match any TestScript.profile id"
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
      "compareToSourcePath" => :not_implemented,
      "value" => :compare_response_expression_to_value,
      "validateProfileId" => :validate_profile_id
    }.freeze

    # Runs every rule the assert has. Returns a warning message when a warningOnly assert
    # fails, nil otherwise
    def evaluate(assertion, response, resource, context)
      TestscriptEval.logger.info(assertion["description"])
      if assertion["direction"] == "request"
        TestscriptEval.logger.info("Skip request validation")
        return nil
      end

      RULES.each do |assert_name, rule|
        send(rule, assert_name, assertion, response, resource, context) if assertion.key?(assert_name)
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
