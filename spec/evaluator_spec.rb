# frozen_string_literal: true

RSpec.describe TestscriptEval::Evaluator do
  let(:base) { "http://fhir.test/fhir" }
  let(:env) { { "baseUrl" => base, "authorization" => "Basic dGVzdDp0ZXN0" } }
  let(:json) { { "Content-Type" => "application/fhir+json" } }
  let(:patient) do
    { "resourceType" => "Patient", "id" => "example",
      "name" => [{ "use" => "official", "given" => %w[Peter James], "family" => "Chalmers" }] }
  end
  let(:ok_outcome) { { "resourceType" => "OperationOutcome", "issue" => [] } }

  def load_script(name)
    TestscriptEval.load_file(File.join(FIXTURES_DIR, "TestScript", name))
  end

  def run(definition, **options)
    TestscriptEval.eval(definition, env, root_dir: FIXTURES_DIR, **options)
  end

  def script(**parts)
    { "resourceType" => "TestScript", "name" => "spec" }.merge(parts.transform_keys(&:to_s))
  end

  def read_patient(*asserts)
    [{ "operation" => { "type" => { "code" => "read" }, "resource" => "Patient", "params" => "/example" } },
     *asserts.map { |a| { "assert" => { "description" => "check" }.merge(a) } }]
  end

  describe "the HL7 TestScript example" do
    let(:definition) { load_script("testscript-example.yaml") }

    before do
      stub_request(:delete, "#{base}/Patient/example").to_return(status: 204)
      stub_request(:put, "#{base}/Patient/example")
        .with(body: hash_including("resourceType" => "Patient", "id" => "example"))
        .to_return(status: 201, body: patient.to_json, headers: json)
      stub_request(:get, "#{base}/Patient/example")
        .to_return(status: 200, body: patient.to_json,
                   headers: json.merge("Last-Modified" => "Mon, 01 Jan 2024 00:00:00 GMT"))
      stub_request(:post, "#{base}/Patient/$validate")
        .with(query: { "profile" => "http://hl7.org/fhir/StructureDefinition/Patient" })
        .to_return(status: 200, body: ok_outcome.to_json, headers: json)
    end

    it "passes and runs setup, tests and teardown" do
      expect(run(definition)).to eq([])
      expect(a_request(:delete, "#{base}/Patient/example")).to have_been_made.twice
      expect(a_request(:get, "#{base}/Patient/example")
        .with(headers: { "Authorization" => "Basic dGVzdDp0ZXN0" })).to have_been_made.twice
      expect(a_request(:post, "#{base}/Patient/$validate?profile=http://hl7.org/fhir/StructureDefinition/Patient")
        .with(body: hash_including("meta" => { "profile" => ["http://hl7.org/fhir/StructureDefinition/Patient"] })))
        .to have_been_made
    end

    it "fails when the server returns another family name, and still tears down" do
      stub_request(:get, "#{base}/Patient/example").to_return(
        status: 200, body: patient.merge("name" => [{ "family" => "Smith", "given" => ["Peter"] }]).to_json, headers: json
      )
      expect { run(definition) }.to raise_error(TestscriptEval::AssertionFailed, /Smith/)
      expect(a_request(:delete, "#{base}/Patient/example")).to have_been_made.twice
    end

    it "reports a failed warningOnly assert as a warning" do
      stub_request(:get, "#{base}/Patient/example").to_return(status: 200, body: patient.to_json, headers: json)
      expect(run(definition)).to contain_exactly(/Last-Modified is present.*Got no value/m)
    end

    it "fails on validation errors" do
      outcome = ok_outcome.merge(
        "issue" => [{ "severity" => "error", "expression" => ["Patient.gender"], "diagnostics" => "bad gender" }]
      )
      stub_request(:post, %r{#{base}/Patient/\$validate}).to_return(status: 422, body: outcome.to_json, headers: json)
      expect { run(definition) }.to raise_error(TestscriptEval::AssertionFailed, /\[error\] Patient.gender: bad gender/)
    end

    it "raises an engine error when $validate cannot run" do
      stub_request(:post, %r{#{base}/Patient/\$validate}).to_return(status: 404, body: "")
      expect { run(definition) }.to raise_error(TestscriptEval::Error, /could not run: status 404/)
    end
  end

  describe "fixtures" do
    let(:fixture_patient) { { "resourceType" => "Patient", "name" => [{ "family" => "Chalmers" }] } }

    it "autocreates fixtures, uses the server-assigned id and autodeletes them" do
      stub_request(:post, "#{base}/Patient").to_return(
        status: 201, headers: { "Location" => "#{base}/Patient/new-id/_history/1" }
      )
      stub_request(:get, "#{base}/Patient/new-id").to_return(status: 200, body: patient.to_json, headers: json)
      stub_request(:delete, "#{base}/Patient/new-id").to_return(status: 204)

      definition = script(
        fixture: [{ "id" => "p", "autocreate" => true, "autodelete" => true,
                    "resource" => { "reference" => "file://resources/patient-no-id.yaml" } }],
        test: [{ "name" => "read", "action" => [
          { "operation" => { "type" => { "code" => "read" }, "resource" => "Patient", "targetId" => "p" } },
          { "assert" => { "description" => "ok", "response" => "okay" } }
        ] }]
      )

      expect(run(definition)).to eq([])
      expect(a_request(:get, "#{base}/Patient/new-id")).to have_been_made
      expect(a_request(:delete, "#{base}/Patient/new-id")).to have_been_made
    end

    it "creates fixtures from files under their id" do
      stub_request(:put, "#{base}/Patient/test-patient").to_return(status: 201, body: "")
      stub_request(:delete, "#{base}/Patient/test-patient").to_return(status: 204)
      stub_request(:get, "#{base}/Patient?name=Chalmers&_count=1").to_return(
        status: 200, body: { "resourceType" => "Bundle", "link" => [] }.to_json, headers: json
      )

      definition = script(
        fixture: [{ "id" => "p", "autocreate" => true, "autodelete" => true,
                    "resource" => { "reference" => "file://resources/patient.yaml" } }],
        variable: [{ "name" => "family", "sourceId" => "p", "expression" => "Patient.name.family" }],
        test: [{ "name" => "search", "action" => [
          { "operation" => { "type" => { "code" => "search" }, "resource" => "Patient",
                             "params" => "?name=${family}&_count=1&empty=" } },
          { "assert" => { "description" => "bundle", "resource" => "Bundle", "navigationLinks" => true } },
          { "assert" => { "description" => "path", "path" => "$.resourceType", "operator" => "equals",
                          "value" => "Bundle", "warningOnly" => true } }
        ] }]
      )

      # jsonpath returns the matches as a list, so `equals` against a string is a warning
      expect(run(definition)).to contain_exactly(/path: Got \["Bundle"\]/)
      expect(a_request(:delete, "#{base}/Patient/test-patient")).to have_been_made
    end

    it "autodeletes created fixtures when a later autocreate fails" do
      stub_request(:put, "#{base}/Patient/test-patient").to_return(status: 201, body: patient.to_json, headers: json)
      stub_request(:post, "#{base}/Patient").to_return(status: 500, body: "boom")
      stub_request(:delete, "#{base}/Patient/example").to_return(status: 204)

      definition = script(
        fixture: [
          { "id" => "a", "autocreate" => true, "autodelete" => true,
            "resource" => { "reference" => "file://resources/patient.yaml" } },
          { "id" => "b", "autocreate" => true, "autodelete" => true,
            "resource" => { "reference" => "file://resources/patient-no-id.yaml" } }
        ]
      )

      expect { run(definition) }.to raise_error(TestscriptEval::Error, /'b' failed with status 500: boom/)
      # `a` was created as test-patient, the server answered with the `example` body
      expect(a_request(:delete, "#{base}/Patient/example")).to have_been_made
    end
  end

  describe "phases" do
    let(:definition) do
      script(
        fixture: [{ "id" => "p", "autocreate" => true, "autodelete" => true,
                    "resource" => { "reference" => "file://resources/patient.yaml" } }],
        variable: [{ "name" => "family", "sourceId" => "p", "expression" => "Patient.name.family" }],
        test: [
          { "name" => "pass", "action" => read_patient({ "response" => "okay" }) },
          { "name" => "warn", "action" => read_patient({ "expression" => "Patient.name.given.first()",
                                                          "value" => "${family}", "warningOnly" => true }) },
          { "name" => "fail", "action" => read_patient({ "expression" => "Patient.name.family = 'Smith'",
                                                          "warningOnly" => false }) }
        ]
      )
    end
    let(:evaluator) { described_class.new(definition, env, root_dir: FIXTURES_DIR) }

    before do
      stub_request(:put, "#{base}/Patient/test-patient").to_return(status: 201, body: "")
      stub_request(:delete, "#{base}/Patient/test-patient").to_return(status: 204)
      stub_request(:get, "#{base}/Patient/example").to_return(status: 200, body: patient.to_json, headers: json)
    end

    it "runs tests one at a time and returns each test's warnings" do
      evaluator.start
      pass, warn, fail = evaluator.tests
      expect(evaluator.run_test(pass)).to eq([])
      expect(evaluator.run_test(warn)).to contain_exactly(/Got "Peter"/)
      expect { evaluator.run_test(fail) }.to raise_error(TestscriptEval::AssertionFailed)
      expect(a_request(:delete, "#{base}/Patient/test-patient")).not_to have_been_made

      evaluator.finish
      evaluator.finish
      expect(a_request(:delete, "#{base}/Patient/test-patient")).to have_been_made.once
    end

    it "cleans up after a failed start" do
      stub_request(:put, "#{base}/Patient/test-patient").to_return(status: 201, body: { "resourceType" => "Patient",
                                                                                         "id" => "test-patient" }.to_json,
                                                                    headers: json)
      definition["variable"] = [{ "name" => "missing", "sourceId" => "p", "expression" => "Patient.gender" }]
      expect { evaluator.start }.to raise_error(TestscriptEval::Error, /missing expression returned no value/)
      evaluator.finish
      expect(a_request(:delete, "#{base}/Patient/test-patient")).to have_been_made
    end

    it "sends requests through a given FHIR client, passing every reply on" do
      fhir_client = FHIR::Client.new(base)
      fhir_client.additional_headers = { "Authorization" => "Bearer token" }
      replies = []
      evaluator.client = TestscriptEval::Client.new(fhir_client) { |reply| replies << reply }

      evaluator.start
      evaluator.run_test(evaluator.tests.first)
      evaluator.finish

      expect(replies.map { |reply| [reply.request[:method], reply.code] })
        .to eq([[:put, 201], [:get, 200], [:delete, 204]])
      expect(a_request(:get, "#{base}/Patient/example").with(headers: { "Authorization" => "Bearer token" }))
        .to have_been_made
    end

    it "validates with a given validator" do
      evaluator.validator = lambda do |resource, profile_url|
        ["#{resource["resourceType"]} does not conform to #{profile_url}"]
      end
      evaluator.start
      test = { "action" => read_patient({ "validateProfileId" => "http://example.org/profile" }) }
      expect { evaluator.run_test(test) }
        .to raise_error(TestscriptEval::AssertionFailed, %r{Patient does not conform to http://example.org/profile})
      expect(a_request(:post, %r{\$validate})).not_to have_been_made
    end
  end

  describe "asserts" do
    before do
      stub_request(:get, "#{base}/Patient/example").to_return(status: 200, body: patient.to_json, headers: json)
    end

    it "evaluates boolean expressions with variables from env" do
      definition = script(
        variable: [{ "name" => "family", "defaultValue" => "Chalmers" }],
        setup: { "action" => read_patient(
          { "expression" => "Patient.name.family = 'Chalmers'" },
          { "expression" => "Patient.name.given.first()", "value" => "${family}", "warningOnly" => true },
          { "responseCode" => "200,201", "operator" => "in" },
          { "contentType" => "application/fhir+json" }
        ) }
      )
      expect(run(definition)).to contain_exactly(/Got "Peter", expected "Chalmers"/)
    end

    it "skips request asserts and fails on unimplemented ones" do
      definition = script(setup: { "action" => read_patient(
        { "direction" => "request", "compareToSourcePath" => "x" },
        { "compareToSourcePath" => "x", "warningOnly" => true }
      ) })
      expect { run(definition) }.to raise_error(TestscriptEval::NotImplementedAssert)
    end

    it "requires an operation before an assert" do
      definition = script(test: [{ "action" => [{ "assert" => { "response" => "okay" } }] }])
      expect { run(definition) }.to raise_error(TestscriptEval::Error, /no preceding operation/)
    end

    it "requires variables without a default value" do
      definition = script(variable: [{ "name" => "missing" }])
      expect { run(definition) }.to raise_error(TestscriptEval::Error, /Missing missing variable/)
    end

    it "treats a 404 body as no resource" do
      stub_request(:get, "#{base}/Patient/example").to_return(status: 404, body: "gone")
      definition = script(setup: { "action" => read_patient({ "response" => "notFound" }, { "resource" => "Patient" }) })
      expect { run(definition) }.to raise_error(TestscriptEval::AssertionFailed, /No resource in the response/)
    end
  end
end
