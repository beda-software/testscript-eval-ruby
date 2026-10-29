# frozen_string_literal: true

require "fhirpath"

module TestscriptEval
  module Misc
    module_function

    # The FHIR R4 model lets FHIRPath resolve choice elements (e.g. `value` for
    # valueCodeableConcept) and types (ofType, is, as) on plain JSON resources
    def fhirpath(resource, expression, context = {})
      Fhirpath.evaluate(resource, expression, context, Fhirpath::Models["r4"])
    end

    def resolve_string_template(value, env)
      return value unless value.is_a?(String)

      value.gsub(/\$\{([\S\s]+?)\}/) { env.fetch(Regexp.last_match(1)).to_s }
    end
  end
end
