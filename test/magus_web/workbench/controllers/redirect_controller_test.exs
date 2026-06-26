defmodule MagusWeb.RedirectControllerTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase
  import Magus.Generators

  test "redirects /prompts/:id/edit to /prompts_library/:id?edit=true", %{conn: conn} do
    user = generate(user())
    conn = log_in_user(conn, user)

    {:ok, prompt} =
      Magus.Library.create_prompt(
        %{name: "Redirect test", content: "content", type: :user},
        actor: user
      )

    conn = get(conn, "/prompts/#{prompt.id}/edit")
    assert redirected_to(conn) =~ "/prompts_library/#{prompt.id}"
    assert redirected_to(conn) =~ "edit=true"
  end
end
