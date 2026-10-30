# frozen_string_literal: true

require "uri"

module TestscriptEval
  # Runs one TestScript: loads fixtures, autocreates them, resolves variables, then runs
  # setup, tests and teardown, and finally autodeletes fixtures
  class Evaluator
    # TestScript operation type codes that map onto another HTTP method, with the path suffix
    # the operation adds
    OPERATION_TYPES = {
      "update" => ["put", ""],
      "read" => ["get", ""],
      "search" => ["get", ""],
      "history" => ["get", "/_history"],
      "create" => ["post", ""],
      "populate" => ["post", "/$populate"],
      "extract" => ["post", "/$extract"]
    }.freeze

    attr_reader :warnings
    # Swappable between phases, e.g. to record each test's requests on its own
    attr_writer :client, :validator

    # `root_dir` resolves file:// fixture references, `include_dir` the `!include` tags of
    # YAML fixtures. `client` defaults to a Client for env baseUrl/authorization, `validator`
    # (validateProfileId asserts) to a ServerValidator, which runs $validate on that server
    def initialize(definition, env, root_dir: Dir.pwd, include_dir: File.join(root_dir, "tests", "resources"),
                   client: nil, validator: nil)
      @definition = definition
      @env = env.transform_keys(&:to_s)
      @root_dir = root_dir
      @include_dir = include_dir
      @client = client
      @validator = validator
      @warnings = []
      @created = []
    end

    def tests
      @definition.fetch("test", [])
    end

    # Runs the whole script and returns the messages of failed warningOnly asserts
    def run
      start
      tests.each { |test| run_test(test) }
      @warnings
    ensure
      finish
    end

    # Loads and autocreates fixtures, resolves variables and runs setup. When it raises,
    # `finish` still cleans up whatever was created
    def start
      logger.info("Test #{@definition["name"]}")
      logger.info("Loading fixtures")
      @fixtures = setup_fixtures
      autocreate_fixtures
      logger.info("Loading variables")
      @variables = setup_variables

      logger.info("Setup")
      eval_actions(@definition.dig("setup", "action") || [])
    end

    # Runs one of the script's tests and returns the messages of its failed warningOnly asserts
    def run_test(test)
      logger.info("Test #{test["name"]}, #{test["description"]}")
      count = @warnings.length
      eval_actions(test.fetch("action", []))
      @warnings[count..]
    end

    # Runs teardown (when `start` got as far as variables), then autodeletes fixtures
    def finish
      return if @finished

      @finished = true
      begin
        if @variables
          logger.info("Teardown")
          eval_actions(@definition.dig("teardown", "action") || [])
        end
      ensure
        autodelete_fixtures if @fixtures
      end
    end

    private

    def logger
      TestscriptEval.logger
    end

    def client
      @client ||= Client.build(@env["baseUrl"], authorization: @env["authorization"])
    end

    def validator
      @validator || ServerValidator.new(client)
    end

    def fixture_definitions
      @definition.fetch("fixture", [])
    end

    def setup_fixtures
      fixture_definitions.to_h do |fixture|
        [fixture["id"], load_fixture(fixture.dig("resource", "reference"))]
      end
    end

    def load_fixture(reference)
      if reference.start_with?("#")
        resource_type, id = reference[1..].split("/")
        contained = @definition.fetch("contained", []).find do |resource|
          resource["resourceType"] == resource_type && resource["id"] == id
        end
        contained || raise(Error, "Contained resource '#{reference}' is not found")
      elsif reference.start_with?("file://")
        path = File.join(@root_dir, reference.delete_prefix("file://"))
        YamlLoader.load(File.read(path), include_dir: @include_dir)
      # relative references to FHIR server baseUrl
      elsif reference.match?(/\A[A-Z]/)
        _response, resource = client.execute(reference, method: "get")
        resource
      else
        raise Error, "Reference '#{reference}' is not supported"
      end
    end

    # `@created` is filled one fixture at a time, so if a later create fails
    # the fixtures already on the server are still autodeleted
    def autocreate_fixtures
      fixture_definitions.each do |definition|
        next unless definition.fetch("autocreate", false)

        fixture_id = definition["id"]
        fixture = @fixtures[fixture_id]
        logger.info("Autocreate fixture #{fixture_id}")
        # A fixture with an id is created under that id (update as create), so references
        # between fixtures (e.g. Patient/<id>) resolve on the server as written
        path, method = fixture.key?("id") ? ["#{fixture["resourceType"]}/#{fixture["id"]}", "put"] : [fixture["resourceType"], "post"]
        response, resource = client.execute(path, method: method, data: fixture)
        unless (200..299).cover?(response.status)
          raise Error, "Autocreate of fixture '#{fixture_id}' failed with status #{response.status}: #{resource}"
        end

        # Later references, variables and autodelete must use the server-assigned id
        @fixtures[fixture_id] = resource || fixture.merge("id" => created_id(response, fixture, fixture_id))
        @created << fixture_id
      end
    end

    # No body returned (e.g. Prefer: return=minimal): take the id from Location
    # ([base]/Type/id/_history/vid), which an update as create may leave out
    def created_id(response, fixture, fixture_id)
      location = response.headers["Location"]
      return fixture["id"] if location.nil? && fixture.key?("id")
      raise Error, "Autocreate of fixture '#{fixture_id}' returned neither a body nor a Location" unless location

      parts = URI.parse(location).path.split("/").reject(&:empty?)
      parts = parts[0...parts.index("_history")] if parts.include?("_history")
      parts.last
    end

    def autodelete_fixtures
      fixture_definitions.reverse_each do |definition|
        next unless definition.fetch("autodelete", false)

        fixture_id = definition["id"]
        # An autocreate fixture whose create did not happen has nothing to delete
        next if definition.fetch("autocreate", false) && !@created.include?(fixture_id)

        fixture = @fixtures[fixture_id]
        unless fixture.is_a?(Hash) && fixture.key?("id")
          logger.warn("Autodelete fixture #{fixture_id} skipped: it has no id")
          next
        end

        logger.info("Autodelete fixture #{fixture_id}")
        response, _resource = client.execute("#{fixture["resourceType"]}/#{fixture["id"]}", method: "delete")
        unless (200..299).cover?(response.status) || [404, 410].include?(response.status)
          logger.warn("Autodelete of fixture #{fixture_id} failed with status #{response.status}")
        end
      end
    end

    def setup_variables
      @definition.fetch("variable", []).to_h do |variable|
        name = variable["name"]
        if variable.key?("sourceId") && variable.key?("expression")
          result = Misc.fhirpath(@fixtures.fetch(variable["sourceId"]), variable["expression"])
          raise Error, "Variable #{name} expression returned no value" if result.empty?

          [name, result.first]
        else
          value = @env.fetch(name, variable["defaultValue"])
          raise Error, "Missing #{name} variable" if value.nil? || value == ""

          [name, value]
        end
      end
    end

    def eval_actions(actions)
      response = nil
      resource = nil
      actions.each do |action|
        if action.key?("operation")
          response, resource = execute_operation(action["operation"])
        else
          raise Error, "Assert has no preceding operation response" if response.nil?

          warning = Assertions.evaluate(action["assert"], response, resource, assertion_context)
          @warnings << warning if warning
        end
      end
    end

    def execute_operation(operation)
      logger.info(operation["description"])
      target = operation["resource"].to_s
      target +=
        if operation.key?("targetId")
          "/#{@fixtures.fetch(operation["targetId"])["id"]}"
        else
          Misc.resolve_string_template(operation.fetch("params", ""), @variables)
        end

      method = "get"
      if operation.key?("type")
        code = operation.dig("type", "code")
        method, suffix = OPERATION_TYPES.fetch(code, [code, ""])
        target += suffix
      end
      method = operation.fetch("method", method)

      data = operation.key?("sourceId") ? @fixtures.fetch(operation["sourceId"]) : nil
      path, query = target.split("?", 2)
      response, resource = client.execute(path, method: method, data: data, params: query_params(query))

      @fixtures[operation["responseId"]] = resource if operation.key?("responseId")
      [response, resource]
    end

    # Like Python's parse_qs: repeated keys are grouped, blank values dropped
    def query_params(query)
      return {} if query.nil? || query.empty?

      URI.decode_www_form(query).each_with_object({}) do |(key, value), params|
        (params[key] ||= []) << value unless value.empty?
      end
    end

    def assertion_context
      Assertions::Context.new(
        variables: @variables, fixtures: @fixtures, validator: validator, profiles: @definition.fetch("profile", [])
      )
    end
  end
end
