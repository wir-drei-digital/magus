defmodule Magus.MCP.ErrorSanitizerTest do
  use ExUnit.Case, async: true

  alias Magus.MCP.ErrorSanitizer

  test "maps common connection reasons to safe categories" do
    assert ErrorSanitizer.categorize(:econnrefused) == "Connection refused"
    assert ErrorSanitizer.categorize(:initialization_timeout) == "Server initialization timeout"
    assert ErrorSanitizer.categorize(:process_not_found) == "Server process unavailable"
    assert ErrorSanitizer.categorize({:ssrf_blocked, "blocked"}) =~ "security policy"

    assert ErrorSanitizer.categorize({:unexpected_tools_response, %{}}) ==
             "Invalid server response"

    assert ErrorSanitizer.categorize({:tls_alert, {:bad_cert, "x"}}) == "TLS verification failed"
  end

  test "unwraps nested transport tuples" do
    assert ErrorSanitizer.categorize({:transport_error, :econnrefused}) == "Connection refused"
  end

  test "falls back to a generic category and never leaks the raw reason" do
    secret = {:headers, %{"authorization" => "Bearer super-secret-token"}}
    category = ErrorSanitizer.categorize(secret)

    assert category == "Connection failed"
    refute category =~ "super-secret-token"
    refute category =~ "authorization"
  end
end
