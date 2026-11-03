# frozen_string_literal: true

module TestscriptEval
  # TestScript variables, evaluated each time they are used: a variable may read the response of
  # an operation that ran after the script started (e.g. `sourceId` = a setup operation's responseId)
  #
  # A variable's value is, in order: the env value of its name, an `expression` (FHIRPath), `path`
  # (JSONPath or XPath) or `headerField` against its `sourceId` (a fixture or response; the last
  # response without one), or its `defaultValue`
  class Variables
    def initialize(definitions, env, evaluator)
      @definitions = definitions.to_h { |variable| [variable["name"], variable] }
      @env = env
      @evaluator = evaluator
    end

    # Common action parameters, as variables while the action runs
    def with(parameters)
      previous = @parameters
      @parameters = (previous || {}).merge(parameters)
      yield
    ensure
      @parameters = previous
    end

    def key?(name)
      @definitions.key?(name) || @env.key?(name)
    end

    def fetch(name)
      return @parameters[name] if @parameters&.key?(name)
      return @env[name] if @env.key?(name) && !@env[name].to_s.empty?

      variable = @definitions.fetch(name) { raise Error, "Unknown variable #{name}" }
      value = evaluate(variable)
      value = variable["defaultValue"] if blank?(value)
      return value unless blank?(value)

      # read from a response or fixture that does not have it: the server's answer, a failed check
      if SOURCE_KEYS.any? { |key| variable.key?(key) }
        raise AssertionFailed, "Variable #{name}: no value in #{variable.fetch("sourceId", "the last response")}"
      end

      raise Error, "Missing #{name} variable#{" (#{variable["hint"]})" if variable["hint"]}"
    end

    SOURCE_KEYS = %w[expression path headerField].freeze

    private

    def blank?(value)
      value.nil? || value.to_s.empty?
    end

    def evaluate(variable)
      if variable.key?("headerField")
        response = @evaluator.response_of(variable["sourceId"])
        response&.headers&.[](variable["headerField"])
      elsif variable.key?("expression")
        first(Misc.evaluate(source(variable), variable["expression"]))
      elsif variable.key?("path")
        first(Misc.path(source(variable), variable["path"]))
      end
    end

    def source(variable)
      return @evaluator.source(variable["sourceId"]) if variable.key?("sourceId")

      last = @evaluator.response_of
      last && @evaluator.last_resource
    end

    def first(result)
      Array(result).first
    end
  end
end
