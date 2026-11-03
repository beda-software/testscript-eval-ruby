# frozen_string_literal: true

require "base64"
require "uri"

module TestscriptEval
  # Runs one TestScript: loads fixtures, autocreates them, resolves variables, then runs
  # setup, tests and teardown, and finally autodeletes fixtures
  class Evaluator
    # TestScript operation type codes (http://terminology.hl7.org/CodeSystem/testscript-operation-codes)
    # with their HTTP method and the path suffix the operation adds. An operation's own `method`
    # wins; other codes are taken as the HTTP method itself
    OPERATION_TYPES = {
      "read" => ["get", ""],
      "vread" => ["get", ""],
      "update" => ["put", ""],
      "updateCreate" => ["put", ""],
      "patch" => ["patch", ""],
      "delete" => ["delete", ""],
      "deleteCondSingle" => ["delete", ""],
      "deleteCondMultiple" => ["delete", ""],
      "history" => ["get", "/_history"],
      "create" => ["post", ""],
      "search" => ["get", ""],
      "batch" => ["post", ""],
      "transaction" => ["post", ""],
      "capabilities" => ["get", "metadata"],
      "validate" => ["post", "/$validate"],
      # a named operation, given in `params` (e.g. `$validate-e-rezept`)
      "operation" => ["post", ""],
      "populate" => ["post", "/$populate"],
      "extract" => ["post", "/$extract"]
    }.freeze

    FILE_REFERENCE = /\.(json|xml|ya?ml)\z/i

    attr_reader :warnings
    # Swappable between phases, e.g. to record each test's requests on its own
    attr_writer :client, :validator

    # `root_dir` resolves file:// fixture references. `!include` tags in YAML fixtures resolve
    # against the fixture's own directory, or `include_dir` when given. `client` defaults to a Client for env baseUrl/authorization, `validator`
    # (validateProfileId asserts) to a ServerValidator, which runs $validate on that server
    def initialize(definition, env, root_dir: Dir.pwd, include_dir: nil, client: nil, validator: nil)
      @definition = definition
      @env = env.transform_keys(&:to_s)
      @root_dir = root_dir
      @include_dir = include_dir
      @client = client
      @validator = validator
      @warnings = []
      @created = []
      # responseId => Response of that operation; its resource also goes in @fixtures
      @responses = {}
      @last = nil
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
      # Variables are evaluated where they are used, as they may read responses of setup operations
      @variables = Variables.new(@definition.fetch("variable", []), @env, self)

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
          @teardown = true
          eval_actions(@definition.dig("teardown", "action") || [])
        end
      ensure
        autodelete_fixtures if @fixtures
      end
    end

    # The resource of a response (by its responseId) or a fixture, for variables and asserts
    def source(id)
      raise Error, "No fixture or response '#{id}'" unless @fixtures.key?(id)

      @fixtures[id]
    end

    # The resource of the last operation's response
    attr_reader :last_resource

    # The Response of an operation by its responseId, or the last one without an id
    def response_of(id = nil)
      return @last if id.nil?

      @responses.fetch(id) { raise Error, "No response '#{id}'" }
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

    # Fixtures without an id (which nothing can refer to) get one, so each is kept on its own
    def fixture_definitions
      @fixture_definitions ||= @definition.fetch("fixture", []).each_with_index.map do |fixture, index|
        fixture.key?("id") ? fixture : fixture.merge("id" => "fixture-#{index + 1}")
      end
    end

    # A fixture without a resource (only an id, e.g. a placeholder a responseId fills) is nil
    def setup_fixtures
      fixture_definitions.to_h do |fixture|
        reference = fixture.dig("resource", "reference")
        [fixture["id"], reference && load_fixture(fixture["id"], reference)]
      end
    end

    def load_fixture(fixture_id, reference)
      if reference.start_with?("#")
        resource_type, id = reference[1..].split("/")
        contained = @definition.fetch("contained", []).find do |resource|
          resource["resourceType"] == resource_type && resource["id"] == id
        end
        contained || raise(Error, "Contained resource '#{reference}' is not found")
      # files: `file://examples/x.json`, or a path (`/examples/x.json`, `../Fixtures/x.xml`,
      # `x.json`), all from the root directory
      elsif reference.start_with?("file://") || reference.match?(FILE_REFERENCE)
        path = File.expand_path(reference.delete_prefix("file://").delete_prefix("/"), @root_dir)
        raise Error, "Fixture '#{fixture_id}': file #{reference} is not found (#{path})" unless File.exist?(path)

        # JSON files are parsed as JSON: valid JSON is not always valid YAML, e.g. with tab indentation
        TestscriptEval.load_file(path, **{ include_dir: @include_dir }.compact)
      # resources on the server: relative references to baseUrl (`Patient/example`) or absolute URLs
      elsif reference.match?(%r{\A([A-Z]|https?://)})
        read_server_fixture(fixture_id, reference)
      else
        raise Error, "Reference '#{reference}' is not supported"
      end
    end

    def read_server_fixture(fixture_id, reference)
      response, resource = client.execute(reference, method: "get")
      return resource if (200..299).cover?(response.status) && resource.is_a?(Hash)

      raise FixtureRejected, "Fixture '#{fixture_id}': #{reference} could not be read from the server " \
                   "(status #{response.status}); the script expects it to exist there"
    end

    # `@created` is filled one fixture at a time, so if a later create fails
    # the fixtures already on the server are still autodeleted
    def autocreate_fixtures
      definitions = fixture_definitions.select { |definition| definition.fetch("autocreate", false) }
      definitions.each do |definition|
        unless @fixtures[definition["id"]].is_a?(Hash)
          raise Error, "Autocreate fixture '#{definition["id"]}' has no resource"
        end
      end

      # Fixtures with ids go in one transaction, so references between them resolve whatever
      # their order, even in cycles, on servers that check references
      together = definitions.select { |definition| transactable?(@fixtures[definition["id"]]) }
      together = [] unless together.length > 1 && autocreate_together(together)

      (definitions - together).each do |definition|
        fixture_id = definition["id"]
        fixture = @fixtures[fixture_id]
        logger.info("Autocreate fixture #{fixture_id}")
        next autocreate_bundle(fixture_id, fixture) if transaction?(fixture)

        # A fixture with an id is created under that id (update as create), so references
        # between fixtures (e.g. Patient/<id>) resolve on the server as written
        path, method = fixture.key?("id") ? ["#{fixture["resourceType"]}/#{fixture["id"]}", "put"] : [fixture["resourceType"], "post"]
        response, resource = client.execute(path, method: method, data: fixture)
        unless (200..299).cover?(response.status)
          raise FixtureRejected, "Autocreate of fixture '#{fixture_id}' failed with status #{response.status}: #{resource}"
        end

        # Later references, variables and autodelete must use the server-assigned id
        @fixtures[fixture_id] = resource || fixture.merge("id" => created_id(response, fixture, fixture_id))
        @created << fixture_id
      end
    end

    def transactable?(fixture)
      fixture.key?("id") && !transaction?(fixture)
    end

    # PUTs the fixtures in one transaction Bundle. False when the server does not take it (e.g.
    # no transaction support, or a fixture it rejects), and the fixtures are created one by one
    def autocreate_together(definitions)
      logger.info("Autocreate fixtures #{definitions.map { |definition| definition["id"] }.join(", ")} in a transaction")
      entries = definitions.map do |definition|
        fixture = @fixtures[definition["id"]]
        { "resource" => fixture, "request" => { "method" => "PUT", "url" => "#{fixture["resourceType"]}/#{fixture["id"]}" } }
      end
      response, resource = client.execute("", method: "post", data: { "resourceType" => "Bundle", "type" => "transaction",
                                                                      "entry" => entries })
      unless (200..299).cover?(response.status) && resource.is_a?(Hash)
        logger.warn("Transaction of the fixtures failed with status #{response.status}, creating them one by one")
        return false
      end

      definitions.each_with_index do |definition, index|
        created = resource.dig("entry", index, "resource")
        @fixtures[definition["id"]] = created if created.is_a?(Hash) && created["resourceType"]
        @created << definition["id"]
      end
      true
    end

    def transaction?(fixture)
      fixture["resourceType"] == "Bundle" && %w[transaction batch].include?(fixture["type"])
    end

    # A transaction or batch Bundle is posted to the server root, which creates its entries; the
    # fixture becomes the response Bundle, and autodelete deletes the entries' resources
    def autocreate_bundle(fixture_id, fixture)
      response, resource = client.execute("", method: "post", data: fixture)
      unless (200..299).cover?(response.status) && resource.is_a?(Hash)
        raise FixtureRejected, "Autocreate of fixture '#{fixture_id}' failed with status #{response.status}: #{resource}"
      end

      @fixtures[fixture_id] = resource
      @created << fixture_id
    end

    # The Type/id of every resource a transaction or batch response reports as created or updated
    def bundle_locations(bundle)
      bundle.fetch("entry", []).filter_map do |entry|
        location = entry.dig("response", "location")
        next unless location

        parts = URI.parse(location).path.split("/").reject(&:empty?)
        parts = parts[0...parts.index("_history")] if parts.include?("_history")
        parts.last(2).join("/")
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
        targets = autodelete_targets(definition, fixture)
        if targets.empty?
          logger.warn("Autodelete fixture #{fixture_id} skipped: it has no id")
          next
        end

        logger.info("Autodelete fixture #{fixture_id}")
        targets.reverse_each { |target| delete(fixture_id, target) }
      end
    end

    def autodelete_targets(definition, fixture)
      return [] unless fixture.is_a?(Hash)
      # an autocreated transaction: the fixture is the response Bundle
      if definition.fetch("autocreate", false) && fixture["resourceType"] == "Bundle" &&
         %w[transaction-response batch-response].include?(fixture["type"])
        return bundle_locations(fixture)
      end

      fixture.key?("id") ? ["#{fixture["resourceType"]}/#{fixture["id"]}"] : []
    end

    def delete(fixture_id, target)
      response, _resource = client.execute(target, method: "delete")
      return if (200..299).cover?(response.status) || [404, 410].include?(response.status)

      logger.warn("Autodelete of fixture #{fixture_id} (#{target}) failed with status #{response.status}")
    end

    def eval_actions(actions, response = nil, resource = nil)
      actions.each do |action|
        if action.key?("common")
          response, resource = eval_common(action["common"], response, resource)
        elsif action.key?("operation")
          response, resource = execute_operation(action["operation"])
        else
          assertion = action["assert"]
          raise Error, "Assert has no preceding operation response" if response.nil? && !assertion.key?("sourceId")

          warning = Assertions.evaluate(assertion, response, resource, assertion_context)
          @warnings << warning if warning
        end
      end
      [response, resource]
    end

    # A TestScript.common action group (R5), run in place with its parameters as variables; its
    # asserts see the response of the operation before it
    def eval_common(common, response, resource)
      key = common["keyRef"]
      group = @definition.fetch("common", []).find { |item| item["key"] == key }
      raise Error, "Common actions '#{key}' are not found" unless group

      parameters = common.fetch("parameter", []).to_h { |parameter| [parameter["name"], resolve(parameter["value"])] }
      @variables.with(parameters) { eval_actions(group.fetch("action", []), response, resource) }
    end

    def execute_operation(operation)
      logger.info(operation["description"])
      code = operation.dig("type", "code")
      method, suffix = OPERATION_TYPES.fetch(code) { [code || "get", ""] }
      method = operation.fetch("method", method)
      path, query = request_target(operation, code, suffix).to_s.split("?", 2)
      path ||= "" # a transaction or batch goes to the server root
      # GET, HEAD and DELETE have no body, whatever sourceId says
      data = operation.key?("sourceId") && !%w[get head delete].include?(method.to_s.downcase) ? source(operation["sourceId"]) : nil
      content_type = operation["contentType"]
      # A Binary sent anywhere but to Binary is its content (e.g. a document to $validate)
      if binary?(data) && !path.start_with?("Binary", "/Binary")
        content_type = data["contentType"]
        data = Base64.decode64(data["data"].to_s)
      end

      response, resource = client.execute(
        path, method: method, data: data, params: query_params(query), headers: request_headers(operation),
              accept: operation["accept"], content_type: content_type
      )
      response, resource = delete_each(path, query, response, resource) if teardown_multiple_delete?(method, query, response)
      @last = response
      @last_resource = resource
      if operation.key?("responseId")
        @responses[operation["responseId"]] = response
        @fixtures[operation["responseId"]] = resource
      end
      [response, resource]
    end

    # The path and query of an operation: its `url`, or the resource type (or the targetId
    # fixture's type and id) with `params` and the operation's suffix
    def request_target(operation, code, suffix)
      return resolve(operation["url"]) if operation.key?("url")
      return suffix if code == "capabilities"

      target = operation["resource"].to_s
      if operation.key?("targetId")
        fixture = source(operation["targetId"])
        raise Error, "targetId '#{operation["targetId"]}' has no resource" unless fixture.is_a?(Hash)

        target = fixture["resourceType"] if target.empty?
        target += "/#{fixture["id"]}"
        target += "/_history/#{fixture.dig("meta", "versionId")}" if code == "vread"
      end

      path, query = resolve(operation.fetch("params", "")).to_s.split("?", 2)
      path ||= ""
      # `params` is a path (`/example`, `$op`), a query (`?name=x`) or a bare query (`profile=x`)
      if path.include?("=") && query.nil?
        query = path
        path = ""
      end
      path = "/#{path}" if path.start_with?("$") && !target.empty?
      [target, path, suffix].join + (query ? "?#{query}" : "")
    end

    def binary?(data)
      data.is_a?(Hash) && data["resourceType"] == "Binary" && data.key?("data")
    end

    # A teardown conditional delete the server refuses for matching several resources (412, e.g.
    # Aidbox): teardown is cleanup, so delete every match instead
    def teardown_multiple_delete?(method, query, response)
      @teardown && method.to_s.casecmp?("delete") && !query.to_s.empty? && response.status == 412
    end

    def delete_each(path, query, response, resource)
      logger.info("Conditional delete #{path}?#{query} matched several resources: deleting each")
      _search, bundle = client.execute(path, method: "get", params: query_params(query))
      targets = bundle.is_a?(Hash) ? bundle.fetch("entry", []).filter_map { |entry| entry["resource"] } : []
      results = targets.map do |target|
        client.execute("#{target["resourceType"]}/#{target["id"]}", method: "delete")
      end
      results.empty? ? [response, resource] : results.last
    end

    def request_headers(operation)
      operation.fetch("requestHeader", []).to_h { |header| [header["field"], resolve(header["value"])] }
    end

    def resolve(string)
      Misc.resolve_string_template(string, @variables)
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
        variables: @variables, fixtures: @fixtures, responses: @responses, validator: validator,
        profiles: profiles
      )
    end

    # TestScript.profile: References with ids (R4), or canonical URLs with the ids in `_profile` (R5)
    def profiles
      @profiles ||= @definition.fetch("profile", []).each_with_index.map do |profile, index|
        next profile if profile.is_a?(Hash)

        { "id" => @definition.dig("_profile", index, "id"), "reference" => profile }
      end
    end
  end
end
