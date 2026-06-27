defmodule Magus.Skills.MaterializerTest do
  use Magus.ResourceCase, async: false

  @moduletag :sandbox

  alias Magus.Skills.Materializer
  alias Magus.Sandbox

  setup do
    {:ok, sandbox_available: Sandbox.Provider.configured?()}
  end

  test "materializes bundle files into the sandbox and is idempotent", %{
    sandbox_available: sandbox_available
  } do
    if sandbox_available do
      owner = generate(user())
      {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: owner)

      bytes =
        build_zip([
          {"SKILL.md", "---\nname: m\ndescription: d\n---\nb"},
          {"scripts/go.py", "print(1)"}
        ])

      {:ok, _} = Magus.Files.Storage.store("skills/#{owner.id}/m.zip", bytes)

      skill = %{id: Ecto.UUID.generate(), name: "m", bundle_path: "skills/#{owner.id}/m.zip"}

      assert {:ok, dir} = Materializer.materialize(conv.id, skill, owner.id)
      assert dir == "/workspace/.skills/m"

      assert {:ok, %{content: "print(1)"}} =
               Sandbox.Orchestrator.read_file(conv.id, "/workspace/.skills/m/scripts/go.py",
                 user_id: owner.id
               )

      # Second call is a no-op (marker present).
      assert {:ok, _} = Materializer.materialize(conv.id, skill, owner.id)
    else
      IO.puts("\n    [sandbox not configured — materializer test skipped]")
    end
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
