# frozen_string_literal: true

module TestscriptEval
  module Operations
    module_function

    def check(condition, message)
      raise AssertionFailed, message unless condition
    end

    def not_implemented(operator, _source, _value)
      raise NotImplementedOperation, "Operation #{operator} is not implemented"
    end

    def contains(_operator, source, values)
      match = values.to_s.split(",").any? { |value| source.respond_to?(:include?) && source.include?(value) }
      check(match, "#{source.inspect} not in #{values}")
    end

    def exists(_operator, source, _value)
      check(!(source.nil? || ((source.is_a?(Array) || source.is_a?(Hash)) && source.empty?)),
            "Exist validation issue")
    end

    def equals(_operator, source, value)
      check(source == value, "Got #{source.inspect}, expected #{value.inspect}")
    end

    def not_empty(_operator, source, _value)
      check(!source.nil?, "Got no value, expected a non-empty one")
    end

    # `source` is the FHIRPath result collection of a boolean expression
    def eval_expression(_operator, source, _value)
      check(source == [true], "Expression evaluated to #{source.inspect}, expected [true]")
    end

    OPERATIONS = {
      "eval" => :eval_expression,
      "exists" => :exists,
      "contains" => :contains,
      "in" => :contains,
      "equals" => :equals,
      "notEmpty" => :not_empty,
      # not implemented operations
      "notEquals" => :not_implemented,
      "notIn" => :not_implemented,
      "greaterThan" => :not_implemented,
      "lessThan" => :not_implemented,
      "empty" => :not_implemented,
      "notContains" => :not_implemented
    }.freeze

    def run(operator, source, value)
      operation = OPERATIONS.fetch(operator) { raise NotImplementedOperation, "Unknown operation #{operator}" }
      send(operation, operator, source, value)
    end
  end
end
