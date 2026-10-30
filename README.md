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

`TestscriptEval.eval` loads fixtures, autocreates them, resolves variables, then runs `setup`,
every `test` and `teardown` (always), and finally autodeletes fixtures.

- A failed assert raises `TestscriptEval::AssertionFailed`.
- A failed `warningOnly` assert does not stop the script; its message is in the returned array.
- Anything else (an unsupported assert or operator, a missing variable, a `$validate` the server
  could not run) raises `TestscriptEval::Error` or one of its subclasses, `warningOnly` or not.

The `env` hash holds `baseUrl`, `authorization` (sent as is in the `Authorization` header) and
values for TestScript variables without a `sourceId`. Without one, it is read from
`FHIR_SERVER_BASE_URL` and `FHIR_SERVER_AUTHORIZATION`.

Options:

- `root_dir:` (default: the current directory) resolves `file://` fixture references, e.g.
  `file://tests/resources/patient.yaml`.
- `include_dir:` (default: `<root_dir>/tests/resources`) resolves `!include path` tags in YAML fixtures.

- `client:` a `TestscriptEval::Client` to send requests with (default: `Client.build(baseUrl, authorization:)`).
  `Client.new(fhir_client) { |reply| ... }` wraps any configured `FHIR::Client` and yields every
  `FHIR::ClientReply`, e.g. to record requests.
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

- Fixtures: contained (`#Type/id`), files (`file://`), server references (`Type/id`), `autocreate`,
  `autodelete`
- Operations: `read`, `search`, `create`, `update`, `delete`, `history`, `populate`, `extract`, or an
  explicit `method` (`get`, `post`, `put`, `delete`), with `params`, `targetId`, `sourceId`, `responseId`
- Asserts: `response`, `responseCode`, `resource`, `headerField`, `contentType`, `path` (JSONPath),
  `expression` (FHIRPath), `value`, `compareToSourceExpression`, `minimumId`, `navigationLinks`,
  `validateProfileId` (via `$validate`)
- Operators: `equals`, `in`, `contains`, `exists`, `notEmpty`, `eval`

## Development

```bash
bundle install
bundle exec rspec
```

<p align="center">Made with ❤️ by <a href="https://beda.software">Beda Software</a></p>
