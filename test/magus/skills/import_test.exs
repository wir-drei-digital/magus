defmodule Magus.Skills.ImportTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills.Import

  defp zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end

  test "imports a bundle into a Skill with a stored archive and manifest" do
    owner = generate(user())

    bytes =
      zip([
        {"SKILL.md",
         "---\nname: importer\ndescription: D\nallowed-tools: web_search\n---\n# I\nRun scripts/go.py"},
        {"scripts/go.py", "print('hi')"}
      ])

    assert {:ok, skill} = Import.import_bundle(bytes, actor: owner)
    assert skill.name == "importer"
    assert skill.requested_tools == ["web_search"]
    assert skill.has_executable_bundle == true
    assert skill.bundle_byte_size == byte_size(bytes)
    assert [%{"path" => "scripts/go.py"} | _] = skill.file_manifest

    # The archive round-trips through storage.
    assert {:ok, ^bytes} = Magus.Files.Storage.get(skill.bundle_path)
  end

  test "propagates a parse error" do
    owner = generate(user())
    bytes = zip([{"SKILL.md", "---\ndescription: no name\n---\nbody"}])
    assert {:error, :missing_name} = Import.import_bundle(bytes, actor: owner)
  end
end

defmodule Magus.Skills.ImportKillSwitchTest do
  # async: false because we mutate application env
  use Magus.ResourceCase, async: false

  alias Magus.Skills.Import

  defp zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end

  setup do
    original = Application.get_env(:magus, Magus.Skills)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:magus, Magus.Skills)
        cfg -> Application.put_env(:magus, Magus.Skills, cfg)
      end
    end)

    :ok
  end

  test "with feature disabled, import_bundle returns {:error, :skills_disabled}" do
    owner = generate(user())

    bytes =
      zip([
        {"SKILL.md", "---\nname: blocked\ndescription: D\n---\nbody"}
      ])

    Application.put_env(:magus, Magus.Skills, enabled: false)

    assert {:error, :skills_disabled} = Import.import_bundle(bytes, actor: owner)
  end
end
