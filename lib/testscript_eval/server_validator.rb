# frozen_string_literal: true

module TestscriptEval
  # The default validator for validateProfileId asserts: runs $validate on the FHIR server under
  # test. A validator is anything that responds to `call(resource, profile_url)` and returns the
  # validation errors, raising Error when no validation happened
  class ServerValidator
    def initialize(client)
      @client = client
    end

    def call(resource, profile_url)
      # Pass the profile both ways: as the $validate `profile` parameter, and in meta.profile,
      # which servers that ignore the parameter (e.g. Aidbox) validate against
      meta = resource.fetch("meta", {})
      payload = resource.merge("meta" => meta.merge("profile" => [*meta.fetch("profile", []), profile_url].uniq))
      response, outcome = @client.execute(
        "#{resource["resourceType"]}/$validate", method: "post", data: payload, params: { "profile" => profile_url }
      )
      # No validation happened (auth, $validate unsupported, server error): an engine/infrastructure
      # error, never a check failure, so warningOnly does not hide it
      if [401, 403, 404, 405].include?(response.status) || response.status >= 500
        raise Error, "$validate against #{profile_url} could not run: status #{response.status}: #{outcome}"
      end

      # Non-2xx: the body comes back wrapped in an ErrorBody
      outcome = parse_json(outcome.to_s) unless outcome.is_a?(Hash)
      unless outcome.is_a?(Hash) && outcome["resourceType"] == "OperationOutcome"
        raise Error, "$validate against #{profile_url} returned no OperationOutcome " \
                     "(status #{response.status}): #{outcome}"
      end

      errors = outcome.fetch("issue", []).select { |issue| %w[error fatal].include?(issue["severity"]) }.map do |issue|
        "[#{issue["severity"]}] #{issue.fetch("expression", []).join(", ")}: " \
          "#{issue["diagnostics"] || issue.dig("details", "text")}"
      end
      # A 2xx, or a 4xx such as 400/422 with an OperationOutcome, is the validation result
      errors << "status #{response.status}" if response.status >= 400 && errors.empty?
      errors
    end

    private

    def parse_json(string)
      JSON.parse(string)
    rescue JSON::ParserError
      nil
    end
  end
end
