# frozen_string_literal: true

require "json"
require "logger"

require_relative "testscript_eval/version"

module TestscriptEval
  class Error < StandardError; end

  # A failed check of an assert. It is the only error a warningOnly assert turns into a
  # warning; anything else (engine, script or infrastructure errors) always fails the script
  class AssertionFailed < Error; end

  # The server did not accept a fixture (autocreate), or does not have one the script reads from
  # it: the server's answer, so a failed check, not an engine error
  class FixtureRejected < AssertionFailed; end

  class NotImplementedOperation < Error; end

  class NotImplementedAssert < Error; end

  class << self
    attr_writer :logger

    def logger
      @logger ||= Logger.new($stderr, progname: "testscript_eval")
    end

    # Runs a TestScript (a Hash parsed from JSON/YAML) against the FHIR server described by
    # `env` ("baseUrl", "authorization" and values for TestScript variables). Raises on the
    # first failed assert and returns the messages of failed warningOnly asserts.
    def eval(definition, env = default_env, **options)
      Evaluator.new(definition, env, **options).run
    end

    def default_env
      {
        "baseUrl" => ENV.fetch("FHIR_SERVER_BASE_URL", nil),
        "authorization" => ENV.fetch("FHIR_SERVER_AUTHORIZATION", nil)
      }
    end

    # Loads a TestScript or a fixture from a .json, .xml or .yaml file
    def load_file(path, include_dir: File.dirname(path))
      content = File.read(path)
      case File.extname(path).downcase
      when ".json" then JSON.parse(content)
      when ".xml" then parse_xml(content)
      else YamlLoader.load(content, include_dir: include_dir)
      end
    end

    # A FHIR R4 resource in XML as the Hash its JSON form parses to
    def parse_xml(xml)
      resource = FHIR::Xml.from_xml(xml)
      raise Error, "Not a FHIR resource in XML: #{xml[0, 100]}" unless resource

      JSON.parse(resource.to_json)
    end
  end
end

require_relative "testscript_eval/yaml_loader"
require_relative "testscript_eval/misc"
require_relative "testscript_eval/client"
require_relative "testscript_eval/server_validator"
require_relative "testscript_eval/operations"
require_relative "testscript_eval/assertions"
require_relative "testscript_eval/variables"
require_relative "testscript_eval/evaluator"
