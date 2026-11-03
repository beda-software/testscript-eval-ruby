# frozen_string_literal: true

require "fhirpath"
require "jsonpath"

module TestscriptEval
  # fhirpath-rb (0.1.7) types a plain resource Hash, such as the root of an expression, as a
  # System type, so `is(FHIR.OperationOutcome)` or `ofType(Patient)` on the root are false. A
  # Hash with a resourceType is that FHIR resource type
  module FhirpathResourceTypeInfo
    def from_value(value, model)
      if value.is_a?(Hash) && value["resourceType"].is_a?(String)
        return Fhirpath::Engine::Nodes::ResourceNode.create_node(value, value["resourceType"]).type_info(model)
      end

      super
    end
  end
  Fhirpath::Engine::Nodes::TypeInfo.singleton_class.prepend(FhirpathResourceTypeInfo)

  module Misc
    module_function

    # The FHIR R4 model lets FHIRPath resolve choice elements (e.g. `value` for
    # valueCodeableConcept) and types (ofType, is, as) on plain JSON resources
    # %resource is the resource itself; %rootResource too, as TestScript resources are not contained
    def fhirpath(resource, expression, context = {})
      Fhirpath.evaluate(resource, expression, { "rootResource" => resource }.merge(context), Fhirpath::Models["r4"])
    end

    # A TestScript expression: a FHIRPath string, or an Expression ({ "expression" => ... })
    def expression_of(expression)
      expression.is_a?(Hash) ? expression["expression"] : expression
    end

    # Evaluates a TestScript expression: FHIRPath, or XPath for an Expression in `application/xml`
    # (e.g. `fhir:Patient/fhir:name/fhir:family/@value`)
    def evaluate(resource, expression, context = {})
      if expression.is_a?(Hash) && expression["language"].to_s.include?("xml")
        return [] unless resource.is_a?(Hash)

        return fhirpath(resource, xpath_to_fhirpath(expression["expression"], resource["resourceType"]))
      end

      fhirpath(resource, expression_of(expression), context)
    end

    # A TestScript `path`: JSONPath (`$.issue[0].code`, also without the `$.`), or an XPath of the
    # XML form (`Bundle/entry/resource/Patient/id`), which is evaluated as FHIRPath on the JSON form
    def path(resource, path)
      return [] unless resource.is_a?(Hash)
      return fhirpath(resource, xpath_to_fhirpath(path, resource["resourceType"])) if xpath?(path)

      JsonPath.new(path).on(resource)
    end

    def xpath?(path)
      !path.start_with?("$") && path.include?("/")
    end

    # Steps are elements; a capitalized step is the resource in a `resource` element (ofType),
    # an `@value` step is the value itself; namespace prefixes and predicates are dropped
    def xpath_to_fhirpath(path, resource_type)
      steps = path.delete_prefix("/").split("/").map { |step| step.sub(/\A\w+:/, "").sub(/\[.*\]\z/, "") }
      steps.shift if steps.first == resource_type
      steps.reject { |step| step.empty? || step.start_with?("@") }.each_with_object([]) do |step, expression|
        expression << (step.match?(/\A[A-Z]/) && !expression.empty? ? "ofType(#{step})" : step)
      end.join(".")
    end

    def resolve_string_template(value, env)
      return value unless value.is_a?(String)

      value.gsub(/\$\{([\S\s]+?)\}/) { env.fetch(Regexp.last_match(1)).to_s }
    end
  end
end
