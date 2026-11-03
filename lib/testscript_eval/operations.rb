# frozen_string_literal: true

module TestscriptEval
  # The assert operators (http://hl7.org/fhir/assert-operator-codes). `source` is what the assert
  # read (a status, header, path or expression result), `value` the assert's value. Values are
  # compared as strings, as TestScript values are strings ("200", "true")
  module Operations
    module_function

    def check(condition, message)
      raise AssertionFailed, message unless condition
    end

    def not_implemented(operator, _source, _value)
      raise NotImplementedOperation, "Operation #{operator} is not implemented"
    end

    # A single-value collection (JSONPath and FHIRPath return collections) is that value
    def scalar(source)
      source.is_a?(Array) && source.length == 1 ? source.first : source
    end

    def same?(source, value)
      source = scalar(source)
      source == value || (!source.nil? && !value.nil? && source.to_s == value.to_s)
    end

    def list(values)
      values.to_s.split(",").map(&:strip)
    end

    def values_of(source)
      source.is_a?(Array) ? source : [source]
    end

    def blank?(source)
      source.nil? || ((source.is_a?(Array) || source.is_a?(Hash) || source.is_a?(String)) && source.empty?)
    end

    def contains?(source, values)
      list(values).any? do |value|
        source = scalar(source)
        source.is_a?(Array) ? source.any? { |item| same?(item, value) } : source.to_s.include?(value)
      end
    end

    def contains(_operator, source, values)
      check(!source.nil? && contains?(source, values), "#{source.inspect} does not contain #{values}")
    end

    def not_contains(_operator, source, values)
      check(source.nil? || !contains?(source, values), "#{source.inspect} contains #{values}")
    end

    def in?(source, values)
      !blank?(source) && values_of(source).all? { |item| list(values).any? { |value| same?(item, value) } }
    end

    def in(_operator, source, values)
      check(in?(source, values), "#{source.inspect} not in #{values}")
    end

    def not_in(_operator, source, values)
      check(!in?(source, values), "#{source.inspect} in #{values}")
    end

    def exists(_operator, source, _value)
      check(!blank?(source) || source == "", "Exist validation issue")
    end

    def empty(_operator, source, _value)
      check(blank?(source), "Got #{source.inspect}, expected no value")
    end

    def equals(_operator, source, value)
      check(same?(source, value), "Got #{scalar(source).inspect}, expected #{value.inspect}")
    end

    def not_equals(_operator, source, value)
      check(!same?(source, value), "Got #{scalar(source).inspect}, expected another value than #{value.inspect}")
    end

    def compare(operator, source, value)
      source = scalar(source)
      left = Float(source.to_s, exception: false)
      right = Float(value.to_s, exception: false)
      left, right = source.to_s, value.to_s if left.nil? || right.nil?
      check(left.public_send(operator == "greaterThan" ? :> : :<, right),
            "#{source.inspect} is not #{operator} #{value.inspect}")
    end

    def not_empty(_operator, source, _value)
      check(!blank?(source), "Got no value, expected a non-empty one")
    end

    # `source` is the FHIRPath result collection of a boolean expression
    def eval_expression(_operator, source, _value)
      check(source == [true], "Expression evaluated to #{source.inspect}, expected [true]")
    end

    OPERATIONS = {
      "eval" => :eval_expression,
      "exists" => :exists,
      "contains" => :contains,
      "notContains" => :not_contains,
      "in" => :in,
      "notIn" => :not_in,
      "equals" => :equals,
      "notEquals" => :not_equals,
      "greaterThan" => :compare,
      "lessThan" => :compare,
      "empty" => :empty,
      "notEmpty" => :not_empty
    }.freeze

    def run(operator, source, value)
      operation = OPERATIONS.fetch(operator) { raise NotImplementedOperation, "Unknown operation #{operator}" }
      send(operation, operator, source, value)
    end
  end
end
