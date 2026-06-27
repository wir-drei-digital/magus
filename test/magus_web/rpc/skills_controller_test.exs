defmodule MagusWeb.Rpc.SkillsControllerTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  defp zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end

  test "imports a bundle and returns the RPC envelope", %{conn: conn} do
    user = generate(user())
    bytes = zip([{"SKILL.md", "---\nname: ctrl-import\ndescription: D\n---\nbody"}])

    upload = %Plug.Upload{
      path: write_tmp(bytes),
      filename: "b.zip",
      content_type: "application/zip"
    }

    conn =
      conn
      |> log_in_user(user)
      |> post(~p"/rpc/skills/import", %{"file" => upload})

    assert %{"success" => true, "data" => %{"name" => "ctrl-import"}} = json_response(conn, 200)
  end

  defp write_tmp(bytes) do
    path = Path.join(System.tmp_dir!(), "skill-#{System.unique_integer([:positive])}.zip")
    File.write!(path, bytes)
    path
  end
end
