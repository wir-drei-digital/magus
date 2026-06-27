defmodule MagusWeb.Workbench.SkillControllerTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  defp zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end

  test "downloads a skill bundle as an attachment", %{conn: conn} do
    owner = generate(user())

    bytes =
      zip([
        {"SKILL.md", "---\nname: dl-skill\ndescription: d\n---\nbody"},
        {"scripts/go.py", "print(1)"}
      ])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: owner)

    conn =
      conn
      |> log_in_user(owner)
      |> get(~p"/skills/#{skill.id}/download")

    assert response(conn, 200) == bytes

    assert {"content-disposition", disp} =
             List.keyfind(conn.resp_headers, "content-disposition", 0)

    assert disp =~ "attachment"
    assert disp =~ "dl-skill.zip"
  end

  test "404 for a skill the user cannot access", %{conn: conn} do
    owner = generate(user())
    stranger = generate(user())
    bytes = zip([{"SKILL.md", "---\nname: priv-skill\ndescription: d\n---\nb"}])
    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: owner)

    conn = conn |> log_in_user(stranger) |> get(~p"/skills/#{skill.id}/download")
    assert conn.status == 404
  end
end
