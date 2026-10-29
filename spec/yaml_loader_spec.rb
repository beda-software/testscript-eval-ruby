# frozen_string_literal: true

RSpec.describe TestscriptEval::YamlLoader do
  let(:resources_dir) { File.join(FIXTURES_DIR, "resources") }

  it "keeps dates as strings and resolves !include" do
    bundle = TestscriptEval.load_file(File.join(resources_dir, "with-include.yaml"))
    expect(bundle["timestamp"]).to eq("2023-03-21T10:00:00Z")
    expect(bundle.dig("entry", 0, "resource", "id")).to eq("test-patient")
  end

  it "still parses other scalars" do
    expect(described_class.load("a: 1\nb: true\nc: '2020-01-01'\nd: 2020-01-01")).to eq(
      "a" => 1, "b" => true, "c" => "2020-01-01", "d" => "2020-01-01"
    )
  end

  it "refuses arbitrary Ruby objects" do
    expect { described_class.load("--- !ruby/object:Object {}\n") }.to raise_error(Psych::DisallowedClass)
  end
end
