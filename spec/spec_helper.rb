# frozen_string_literal: true

require "testscript_eval"
require "webmock/rspec"

FIXTURES_DIR = File.expand_path("fixtures", __dir__)

TestscriptEval.logger = Logger.new(nil)
FHIR.logger = Logger.new(nil)

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
