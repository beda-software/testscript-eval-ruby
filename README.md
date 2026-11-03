# testscript_eval

An engine that runs [FHIR TestScript](https://hl7.org/fhir/R4/testscript.html) resources against a
FHIR server. It is a Ruby port of [testscript-eval-py](https://github.com/beda-software/testscript-eval-py),
built on [fhir_client](https://github.com/fhir-crucible/fhir_client) and
[fhirpath-rb](https://github.com/beda-software/fhirpath-ruby).

## Install

```ruby
gem "testscript_eval", git: "https://github.com/beda-software/testscript-eval-ruby"
```

## Usage

```ruby
require "testscript_eval"

definition = TestscriptEval.load_file("TestScript/testscript-example.yaml")
warnings = TestscriptEval.eval(definition, {
  "baseUrl" => "http://localhost:8080/fhir",
  "authorization" => "Basic cm9vdDpzZWNyZXQ="
})
```

`TestscriptEval.eval` loads fixtures, autocreates them, then runs `setup`, every `test` and
`teardown` (always), and finally autodeletes fixtures. Variables are evaluated where they are used,
so they can read the responses of earlier operations.

- A failed assert raises `TestscriptEval::AssertionFailed`. So does a fixture the server rejects
  or does not have (`TestscriptEval::FixtureRejected`), as that is the server's answer.
- A failed `warningOnly` assert does not stop the script; its message is in the returned array.
- Anything else (an unsupported assert or operator, a missing variable, a `$validate` the server
  could not run) raises `TestscriptEval::Error` or one of its subclasses, `warningOnly` or not.

The `env` hash holds `baseUrl`, `authorization` (sent as is in the `Authorization` header) and
values for TestScript variables without a `sourceId`. Without one, it is read from
`FHIR_SERVER_BASE_URL` and `FHIR_SERVER_AUTHORIZATION`.

Options:

- `root_dir:` (default: the current directory) resolves file fixture references (`.json`, `.xml`, `.yaml`),
  as a `file://` URL or a path from the root: `file://tests/resources/patient.yaml`,
  `/tests/resources/patient.yaml`, `../Fixtures/patient.xml`.
- `include_dir:` (default: `<root_dir>/tests/resources`) resolves `!include path` tags in YAML fixtures.

- `client:` a `TestscriptEval::Client` to send requests with (default: `Client.build(baseUrl, authorization:)`).
  `Client.new(fhir_client) { |reply| ... }` wraps any configured `FHIR::Client` and yields every
  `FHIR::ClientReply`, e.g. to record requests. With `xml: false` (for JSON-only servers such as
  Aidbox), operations that ask for XML are sent and accepted as JSON.
- `validator:` what `validateProfileId` asserts call: anything responding to `call(resource, profile_url)` that
  returns the validation error messages (default: `ServerValidator`, `$validate` on the server under test).

YAML files are loaded safely, with dates and datetimes kept as strings.

### Running a script step by step

`TestscriptEval.eval` is `Evaluator#run`, which is made of three phases that can also be called one at a time,
e.g. to report every test separately:

```ruby
evaluator = TestscriptEval::Evaluator.new(definition, env)
begin
  evaluator.start                       # fixtures, autocreate, variables, setup
  evaluator.tests.each do |test|
    warnings = evaluator.run_test(test) # raises on a failed assert
  end
ensure
  evaluator.finish                      # teardown, autodelete; also after a failed start
end
```

`client=` and `validator=` swap the client and validator between phases.

### Logging

The engine logs to `TestscriptEval.logger` (stderr). fhir_client logs every request to stdout at debug
level; quiet it with `FHIR.logger.level = Logger::WARN`.

## Supported features

- Fixtures: contained (`#Type/id`), files (`file://`, `/path`, relative paths; JSON, XML or YAML),
  server references (`Type/id` or a URL), fixtures without a resource (placeholders) or an id.
  `autocreate` puts fixtures with ids in one transaction (so references between them resolve, even in
  cycles; one by one when the server refuses it), posts transaction/batch Bundles to the server root;
  `autodelete` deletes them, including what a transaction Bundle created.
- Operations: every `testscript-operation-codes` type (`read`, `vread`, `search`, `create`, `update`,
  `updateCreate`, `patch`, `delete`, `history`, `transaction`, `batch`, `capabilities`, `validate`,
  `operation` with `params: $name`, …) or an explicit `method`, with `url`, `params` (path, query or
  `$operation`), `resource`, `targetId`, `sourceId` (a Binary goes as its content), `responseId`,
  `requestHeader`, `accept` and `contentType` (`json`, `xml` or a MIME type)
- Variables: `defaultValue`, env values, `expression` (FHIRPath, or XPath in an `application/xml`
  Expression), `path` (JSONPath or XPath), `headerField`, against a `sourceId` fixture or response or
  the last response
- Asserts: `response` (all response codes), `responseCode`, `resource`, `headerField`, `contentType`,
  `path`, `expression`, `value`, `compareToSourceExpression`, `compareToSourcePath`, `minimumId`,
  `navigationLinks`, `requestURL`, `requestMethod`, `validateProfileId`, `sourceId`, and
  `direction: request`; `${variables}` in values, paths and expressions
- Operators: `equals`, `notEquals`, `in`, `notIn`, `contains`, `notContains`, `greaterThan`, `lessThan`,
  `empty`, `notEmpty`, `exists`, `eval`
- R5: `common` actions with parameters, `profile` as canonical URLs with ids in `_profile`
- Not supported: `origin`/`destination` (every operation goes to the one server), `stopTestOnFail`
  (a failed assert always ends its test)

## Development

```bash
bundle install
bundle exec rspec
```

<p align="center">Made with ❤️ by <a href="https://beda.software">Beda Software</a></p>
