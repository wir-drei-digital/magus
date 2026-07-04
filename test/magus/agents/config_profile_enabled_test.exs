defmodule Magus.Agents.ConfigProfileEnabledTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Config

  test "profile_enabled?/1 reflects the user's setting" do
    off = generate(user())
    assert Config.profile_enabled?(to_string(off.id)) == false

    on =
      generate(user())
      |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true},
        authorize?: false
      )
      |> Ash.update!()

    assert Config.profile_enabled?(to_string(on.id)) == true
  end

  test "profile_enabled?/1 is false for an unknown user id" do
    assert Config.profile_enabled?(Ecto.UUID.generate()) == false
  end
end
