# frozen_string_literal: true

require "psych"

module TestscriptEval
  # Safe YAML loading as FHIR resources need it: dates and datetimes stay strings (FHIR
  # primitives, not Ruby Date/Time objects), and `!include path` embeds another YAML file
  # resolved against `include_dir`
  module YamlLoader
    class Scanner < Psych::ScalarScanner
      DATE_LIKE = /\A\d{4}-\d{1,2}-\d{1,2}(?:[Tt ]|\z)/

      def tokenize(string)
        return string if string.match?(DATE_LIKE)

        super
      end
    end

    class Visitor < Psych::Visitors::ToRuby
      def initialize(scanner, class_loader, include_dir:)
        super(scanner, class_loader)
        @include_dir = include_dir
      end

      def visit_Psych_Nodes_Scalar(node) # rubocop:disable Naming/MethodName
        return super unless node.tag == "!include"

        path = File.expand_path(node.value, @include_dir)
        YamlLoader.load(File.read(path), include_dir: @include_dir)
      end
    end

    module_function

    def load(content, include_dir: Dir.pwd)
      document = Psych.parse(content)
      return nil unless document

      class_loader = Psych::ClassLoader::Restricted.new([], [])
      Visitor.new(Scanner.new(class_loader), class_loader, include_dir: include_dir).accept(document)
    end
  end
end
