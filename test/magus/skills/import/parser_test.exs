defmodule Magus.Skills.Import.ParserTest do
  use ExUnit.Case, async: true

  alias Magus.Skills.Import.Parser

  test "parses standard frontmatter and maps allowed-tools" do
    md = """
    ---
    name: pdf-filler
    description: Fill PDF forms
    license: MIT
    allowed-tools: web_search run_code
    ---
    # PDF
    Do the thing.
    """

    assert {:ok, m} = Parser.parse(md)
    assert m.name == "pdf-filler"
    assert m.description == "Fill PDF forms"
    assert m.license == "MIT"
    assert m.requested_tools == ["web_search", "run_code"]
    assert m.body =~ "Do the thing."
    assert m.source_format == :skill_md
  end

  test "extracts Magus extensions from metadata x-magus" do
    md = """
    ---
    name: with-secrets
    description: d
    metadata:
      x-magus: "{\\"version\\":\\"2.0\\",\\"required_secrets\\":[{\\"key\\":\\"OPENAI_API_KEY\\",\\"description\\":\\"key\\"}]}"
    ---
    body
    """

    assert {:ok, m} = Parser.parse(md)
    assert m.version == "2.0"
    assert [%{"key" => "OPENAI_API_KEY"}] = m.required_secrets
    refute Map.has_key?(m.metadata, "x-magus")
  end

  test "rejects frontmatter without a name" do
    assert {:error, :missing_name} = Parser.parse("---\ndescription: d\n---\nbody")
  end

  test "returns :invalid_frontmatter when no YAML frontmatter present" do
    assert {:error, :invalid_frontmatter} = Parser.parse("just a body with no frontmatter")
  end

  test "accepts allowed-tools given as a YAML list" do
    md = """
    ---
    name: listy
    description: d
    allowed-tools:
      - web_search
      - run_code
    ---
    body
    """

    assert {:ok, m} = Parser.parse(md)
    assert m.requested_tools == ["web_search", "run_code"]
  end

  test "tolerates malformed x-magus JSON, falling back to defaults" do
    md = """
    ---
    name: bad-json
    description: d
    metadata:
      x-magus: "{not valid json"
    ---
    body
    """

    assert {:ok, m} = Parser.parse(md)
    assert m.required_secrets == []
    assert m.runtime_hints == %{}
    assert m.version == nil
  end
end
