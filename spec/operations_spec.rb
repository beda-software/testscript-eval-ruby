# frozen_string_literal: true

RSpec.describe TestscriptEval::Operations do
  def run(operator, source, value = nil)
    described_class.run(operator, source, value)
  end

  it "checks equality" do
    expect { run("equals", "a", "a") }.not_to raise_error
    expect { run("equals", "a", "b") }.to raise_error(TestscriptEval::AssertionFailed, /expected "b"/)
  end

  it "checks comma-separated alternatives with in/contains" do
    expect { run("in", "204", "200,204") }.not_to raise_error
    expect { run("contains", "500", "200,204") }.to raise_error(TestscriptEval::AssertionFailed)
    expect { run("in", nil, "200") }.to raise_error(TestscriptEval::AssertionFailed)
  end

  it "checks existence" do
    expect { run("exists", ["x"]) }.not_to raise_error
    [nil, [], {}].each do |empty|
      expect { run("exists", empty) }.to raise_error(TestscriptEval::AssertionFailed)
    end
  end

  it "checks notEmpty" do
    expect { run("notEmpty", "Mon, 01 Jan 2024 00:00:00 GMT") }.not_to raise_error
    expect { run("notEmpty", nil) }.to raise_error(TestscriptEval::AssertionFailed)
  end

  it "checks a boolean FHIRPath result with eval" do
    expect { run("eval", [true]) }.not_to raise_error
    expect { run("eval", [false]) }.to raise_error(TestscriptEval::AssertionFailed)
    expect { run("eval", []) }.to raise_error(TestscriptEval::AssertionFailed)
  end

  it "raises an engine error, not a failed check, for unimplemented operations" do
    expect { run("greaterThan", 1, 2) }.to raise_error(TestscriptEval::NotImplementedOperation)
    expect { run("bogus", 1, 2) }.to raise_error(TestscriptEval::NotImplementedOperation)
  end
end
