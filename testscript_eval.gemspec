# frozen_string_literal: true

require_relative "lib/testscript_eval/version"

Gem::Specification.new do |spec|
  spec.name = "testscript_eval"
  spec.version = TestscriptEval::VERSION
  spec.authors = ["beda.software"]
  spec.email = ["ilya@beda.software"]

  spec.summary = "TestScript FHIR resource evaluator"
  spec.description = "An engine that runs FHIR TestScript resources against a FHIR server."
  spec.homepage = "https://github.com/beda-software/testscript-eval-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "fhir_client", "~> 6.2"
  spec.add_dependency "fhirpath-rb", "~> 0.1.3"
  spec.add_dependency "jsonpath", "~> 1.1"
end
