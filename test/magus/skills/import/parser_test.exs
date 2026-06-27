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
  end

  test "rejects frontmatter without a name" do
    assert {:error, :missing_name} = Parser.parse("---\ndescription: d\n---\nbody")
  end
end
