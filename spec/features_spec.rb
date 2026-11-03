# frozen_string_literal: true

require "base64"
require "tmpdir"

RSpec.describe "TestScript features" do
  let(:base) { "http://fhir.test/fhir" }
  let(:json) { { "Content-Type" => "application/fhir+json" } }
  let(:patient) { { "resourceType" => "Patient", "id" => "p1", "name" => [{ "family" => "Chalmers" }] } }

  def run(definition, xml: true, root_dir: FIXTURES_DIR, env: {})
    client = TestscriptEval::Client.build(base, xml:)
    TestscriptEval::Evaluator.new(definition, env, root_dir:, client:).run
  end

  def script(**parts)
    { "resourceType" => "TestScript", "name" => "spec" }.merge(parts.transform_keys(&:to_s))
  end

  def operation(**fields)
    { "operation" => fields.transform_keys(&:to_s) }
  end

  def assertion(**fields)
    { "assert" => { "description" => "check" }.merge(fields.transform_keys(&:to_s)) }
  end

  describe "operations" do
    it "maps operation types onto requests, with params as path, query or a named operation" do
      stub_request(:put, "#{base}/Patient/p1").to_return(status: 201, body: patient.to_json, headers: json)
      stub_request(:post, "#{base}/$validate?profile=http://x/sd").to_return(status: 200, body: "{}", headers: json)
      stub_request(:post, "#{base}/$validate-e-rezept").to_return(status: 200, body: "{}", headers: json)
      stub_request(:get, "#{base}/metadata").to_return(status: 200, body: "{}", headers: json)
      stub_request(:delete, "#{base}/Patient/p1").to_return(status: 204)

      definition = script(
        fixture: [{ "id" => "p", "resource" => { "reference" => "/resources/patient.yaml" } }],
        setup: { "action" => [
          operation(type: { "code" => "updateCreate" }, resource: "Patient", params: "/p1", sourceId: "p"),
          assertion(response: "created"),
          operation(type: { "code" => "validate" }, params: "profile=http://x/sd", sourceId: "p"),
          assertion(response: "okay"),
          operation(type: { "code" => "operation" }, params: "$validate-e-rezept", sourceId: "p"),
          assertion(response: "okay"),
          operation(type: { "code" => "capabilities" }),
          assertion(response: "okay"),
          operation(method: "delete", url: "Patient/p1"),
          assertion(response: "noContent")
        ] }
      )

      expect(run(definition)).to eq([])
    end

    it "sends request headers and reads variables from a responseId and its headers" do
      stub_request(:post, "#{base}/Patient").with(headers: { "Prefer" => "return=representation" })
        .to_return(status: 201, body: patient.to_json, headers: json.merge("Location" => "#{base}/Patient/p1/_history/1"))
      stub_request(:get, "#{base}/Patient/p1/_history/1").to_return(status: 200, body: patient.to_json, headers: json)
      stub_request(:get, "#{base}/Patient/p1").to_return(status: 200, body: patient.to_json, headers: json)

      definition = script(
        fixture: [{ "id" => "p", "resource" => { "reference" => "/resources/patient.yaml" } }],
        variable: [
          { "name" => "createdId", "sourceId" => "create-response", "expression" => "Patient.id" },
          { "name" => "location", "sourceId" => "create-response", "headerField" => "Location" },
          { "name" => "family", "sourceId" => "create-response", "path" => "Patient/name/family/@value" }
        ],
        setup: { "action" => [
          operation(type: { "code" => "create" }, resource: "Patient", sourceId: "p", responseId: "create-response",
                    requestHeader: [{ "field" => "Prefer", "value" => "return=representation" }])
        ] },
        test: [{ "action" => [
          operation(type: { "code" => "read" }, url: "${location}"),
          assertion(response: "okay"),
          operation(type: { "code" => "read" }, resource: "Patient", params: "/${createdId}"),
          assertion(expression: "Patient.name.family", value: "${family}"),
          assertion(sourceId: "create-response", headerField: "Location", operator: "contains", value: "_history")
        ] }]
      )

      expect(run(definition)).to eq([])
    end

    it "says what a failed assert evaluated" do
      outcome = { "resourceType" => "OperationOutcome", "issue" => [{ "severity" => "warning" }] }
      stub_request(:get, "#{base}/OperationOutcome/o1").to_return(status: 200, body: outcome.to_json, headers: json)

      definition = script(
        variable: [{ "name" => "severity", "defaultValue" => "error" }],
        test: [{ "action" => [
          operation(type: { "code" => "read" }, resource: "OperationOutcome", params: "/o1"),
          assertion(description: "Confirm that we have errors.",
                    expression: "issue.where(severity='${severity}').count()>0", value: "true", warningOnly: true),
          assertion(description: "Path", path: "$.issue[0].severity", value: "error", warningOnly: true),
          assertion(description: "Header", headerField: "Location", operator: "notEmpty", warningOnly: true)
        ] }]
      )

      expect(run(definition)).to eq([
        "Confirm that we have errors.: Expression `issue.where(severity='error').count()>0` on the response: " \
        'Got false, expected "true"',
        'Path: Path `$.issue[0].severity` on the response: Got "warning", expected "error"',
        "Header: Response header Location: Got no value, expected a non-empty one"
      ])
    end

    it "keeps the OperationOutcome of an error response for asserts" do
      outcome = { "resourceType" => "OperationOutcome", "issue" => [{ "severity" => "error", "code" => "invalid" }] }
      stub_request(:post, "#{base}/Patient").to_return(status: 422, body: outcome.to_json, headers: json)

      definition = script(
        fixture: [{ "id" => "p", "resource" => { "reference" => "/resources/patient.yaml" } }],
        test: [{ "action" => [
          operation(type: { "code" => "create" }, resource: "Patient", sourceId: "p"),
          assertion(response: "unprocessable"),
          assertion(path: "issue[0].code", value: "invalid"),
          assertion(expression: "issue.count()", operator: "greaterThan", value: "0")
        ] }]
      )

      expect(run(definition)).to eq([])
    end
  end

  describe "formats" do
    let(:patient_xml) do
      '<Patient xmlns="http://hl7.org/fhir"><id value="p1"/><name><family value="Chalmers"/></name></Patient>'
    end

    it "sends and accepts XML when asked, and evaluates XPath expressions" do
      stub_request(:put, "#{base}/Patient/p1")
        .with(headers: { "Content-Type" => "application/fhir+xml" }) { |request| request.body.include?("<Patient") }
        .to_return(status: 200, body: patient_xml, headers: { "Content-Type" => "application/fhir+xml" })

      definition = script(
        fixture: [{ "id" => "p", "resource" => { "reference" => "/resources/patient.yaml" } }],
        test: [{ "action" => [
          operation(type: { "code" => "update" }, resource: "Patient", params: "/p1", sourceId: "p",
                    accept: "xml", contentType: "xml"),
          assertion(contentType: "xml"),
          assertion(direction: "request", headerField: "Accept", operator: "contains", value: "xml"),
          assertion(expression: { "language" => "application/xml",
                                  "expression" => "fhir:Patient/fhir:name/fhir:family/@value" },
                    operator: "equals", value: "Chalmers")
        ] }]
      )

      expect(run(definition)).to eq([])
    end

    it "uses JSON instead when XML is off" do
      stub_request(:get, "#{base}/Patient/p1").with(headers: { "Accept" => "application/fhir+json" })
        .to_return(status: 200, body: patient.to_json, headers: json)

      definition = script(test: [{ "action" => [
        operation(type: { "code" => "read" }, resource: "Patient", params: "/p1", accept: "xml"),
        assertion(resource: "Patient")
      ] }])

      expect(run(definition, xml: false)).to eq([])
    end

    it "loads XML fixture files and sends a Binary fixture as its content" do
      document = '{"resourceType":"Bundle","type":"document"}'
      binary = { "resourceType" => "Binary", "contentType" => "application/fhir+json",
                 "data" => Base64.strict_encode64(document) }
      stub_request(:post, "#{base}/$validate").with(body: document, headers: { "Content-Type" => "application/fhir+json" })
        .to_return(status: 200, body: { "resourceType" => "OperationOutcome", "issue" => [] }.to_json, headers: json)

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "Fixtures"))
        File.write(File.join(dir, "Fixtures", "patient.xml"), patient_xml)
        File.write(File.join(dir, "binary.json"), binary.to_json)
        definition = script(
          fixture: [{ "id" => "p", "resource" => { "reference" => "Fixtures/patient.xml" } },
                    { "id" => "doc", "resource" => { "reference" => "binary.json" } }],
          variable: [{ "name" => "family", "sourceId" => "p", "expression" => "Patient.name.family" }],
          test: [{ "action" => [
            operation(type: { "code" => "validate" }, sourceId: "doc", contentType: "json"),
            assertion(expression: "is(FHIR.OperationOutcome)", value: "true"),
            assertion(sourceId: "p", expression: "Patient.name.family = '${family}'")
          ] }]
        )

        expect(run(definition, root_dir: dir)).to eq([])
      end
    end
  end

  describe "fixtures" do
    it "autocreates a transaction Bundle and autodeletes the resources it created" do
      bundle = { "resourceType" => "Bundle", "type" => "transaction",
                 "entry" => [{ "resource" => patient.except("id"), "request" => { "method" => "POST", "url" => "Patient" } }] }
      reply = { "resourceType" => "Bundle", "type" => "transaction-response",
                "entry" => [{ "response" => { "status" => "201", "location" => "Patient/new/_history/1" } }] }
      stub_request(:post, "#{base}/").to_return(status: 200, body: reply.to_json, headers: json)
      stub_request(:get, "#{base}/Patient/new").to_return(status: 200, body: patient.to_json, headers: json)
      stub_request(:delete, "#{base}/Patient/new").to_return(status: 204)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "bundle.json"), bundle.to_json)
        definition = script(
          fixture: [{ "id" => "b", "autocreate" => true, "autodelete" => true,
                      "resource" => { "reference" => "/bundle.json" } },
                    { "id" => "placeholder" }, { "resource" => { "reference" => "/bundle.json" } }],
          variable: [{ "name" => "id", "sourceId" => "b",
                       "expression" => "Bundle.entry.response.location.first().replaceMatches('^Patient/([^/]+).*$', '$1')" }],
          test: [{ "action" => [operation(type: { "code" => "read" }, resource: "Patient", params: "/${id}"),
                                assertion(response: "okay")] }]
        )

        expect(run(definition, root_dir: dir)).to eq([])
      end
      expect(a_request(:delete, "#{base}/Patient/new")).to have_been_made
    end

    it "autocreates fixtures with ids in one transaction, and one by one when the server refuses it" do
      a = { "resourceType" => "Patient", "id" => "a", "link" => [{ "other" => { "reference" => "Patient/b" } }] }
      b = { "resourceType" => "Patient", "id" => "b", "link" => [{ "other" => { "reference" => "Patient/a" } }] }
      reply = { "resourceType" => "Bundle", "type" => "transaction-response",
                "entry" => [{ "resource" => a }, { "resource" => b }] }
      transaction = stub_request(:post, "#{base}/")
        .with { |request| JSON.parse(request.body)["entry"].map { |e| e.dig("request", "url") } == %w[Patient/a Patient/b] }
        .to_return(status: 200, body: reply.to_json, headers: json)
      %w[a b].each { |id| stub_request(:delete, "#{base}/Patient/#{id}").to_return(status: 204) }

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.json"), a.to_json)
        File.write(File.join(dir, "b.json"), b.to_json)
        definition = script(fixture: %w[a b].map do |id|
          { "id" => id, "autocreate" => true, "autodelete" => true, "resource" => { "reference" => "#{id}.json" } }
        end)

        expect(run(definition, root_dir: dir)).to eq([])
        expect(transaction).to have_been_made.once
        expect(a_request(:delete, "#{base}/Patient/a")).to have_been_made

        stub_request(:post, "#{base}/").to_return(status: 405, body: "")
        %w[a b].each do |id|
          stub_request(:put, "#{base}/Patient/#{id}").to_return(status: 201, body: (id == "a" ? a : b).to_json, headers: json)
        end
        expect(run(definition, root_dir: dir)).to eq([])
        expect(a_request(:put, "#{base}/Patient/b")).to have_been_made
      end
    end

    it "fails, not errors, when the server rejects a fixture" do
      stub_request(:put, "#{base}/Patient/test-patient").to_return(status: 422, body: "")

      definition = script(fixture: [{ "id" => "p", "autocreate" => true,
                                      "resource" => { "reference" => "/resources/patient.yaml" } }])

      expect { run(definition) }.to raise_error(TestscriptEval::FixtureRejected, /failed with status 422/)
    end

    it "deletes every match of a teardown conditional delete the server refuses for multiple matches" do
      stub_request(:delete, "#{base}/Medication?code=x").to_return(status: 412, body: "")
      search = { "resourceType" => "Bundle", "entry" => %w[m1 m2].map { |id| { "resource" => { "resourceType" => "Medication", "id" => id } } } }
      stub_request(:get, "#{base}/Medication?code=x").to_return(status: 200, body: search.to_json, headers: json)
      %w[m1 m2].each { |id| stub_request(:delete, "#{base}/Medication/#{id}").to_return(status: 204) }

      definition = script(teardown: { "action" => [operation(type: { "code" => "delete" }, resource: "Medication", params: "?code=x")] })

      expect(run(definition)).to eq([])
      expect(a_request(:delete, "#{base}/Medication/m1")).to have_been_made
      expect(a_request(:delete, "#{base}/Medication/m2")).to have_been_made
    end

    it "explains a server fixture that does not exist" do
      stub_request(:get, "#{base}/Patient/missing").to_return(status: 404, body: "")

      definition = script(fixture: [{ "id" => "p", "resource" => { "reference" => "Patient/missing" } }])

      expect { run(definition) }.to raise_error(TestscriptEval::Error, %r{Patient/missing could not be read .*status 404})
    end
  end

  describe "scripts" do
    it "runs common actions with their parameters, and resolves R5 profile ids" do
      stub_request(:get, "#{base}/Patient/p1").to_return(status: 200, body: patient.to_json, headers: json)
      validator = ->(_resource, profile_url) { profile_url == "http://hl7.org/fhir/StructureDefinition/Patient" ? [] : ["wrong"] }

      definition = script(
        profile: ["http://hl7.org/fhir/StructureDefinition/Patient"], _profile: [{ "id" => "patient-profile" }],
        common: [{ "key" => "read-asserts", "parameter" => [{ "name" => "family" }], "action" => [
          assertion(response: "okay"),
          assertion(expression: "Patient.name.family", value: "${family}"),
          assertion(validateProfileId: "patient-profile")
        ] }],
        test: [{ "action" => [
          operation(type: { "code" => "read" }, resource: "Patient", params: "/p1"),
          { "common" => { "keyRef" => "read-asserts", "parameter" => [{ "name" => "family", "value" => "Chalmers" }] } }
        ] }]
      )

      client = TestscriptEval::Client.build(base)
      expect(TestscriptEval::Evaluator.new(definition, {}, client:, validator:).run).to eq([])
    end
  end
end
