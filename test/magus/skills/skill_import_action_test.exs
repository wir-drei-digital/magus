defmodule Magus.Skills.SkillImportActionTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills

  test "import_skill accepts bundle fields and sets the owner" do
    owner = generate(user())

    {:ok, skill} =
      Skills.import_skill(
        %{
          name: "imported",
          description: "d",
          body: "# I",
          requested_tools: ["web_search"],
          bundle_path: "skills/#{owner.id}/abc.zip",
          bundle_backend: "local",
          bundle_byte_size: 123,
          file_manifest: [%{"path" => "scripts/run.py", "size" => 8}],
          has_executable_bundle: true,
          source_format: :skill_md
        },
        actor: owner
      )

    assert skill.has_executable_bundle == true
    assert skill.bundle_path == "skills/#{owner.id}/abc.zip"
    assert skill.user_id == owner.id
  end
end
