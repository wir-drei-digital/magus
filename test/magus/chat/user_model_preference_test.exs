defmodule Magus.Chat.UserModelPreferenceTest do
  @moduledoc "Per-user model curation: favorite, hide, order."
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  setup do
    user = generate(user())
    model = generate(model())
    %{user: user, model: model}
  end

  describe "set_favorite / set_hidden upsert" do
    test "favoriting creates one row, then hiding updates the same row", %{user: user, model: model} do
      {:ok, fav} = Chat.set_model_favorite(%{model_id: model.id, favorite?: true}, actor: user)
      assert fav.favorite? == true
      assert fav.hidden? == false

      {:ok, hid} = Chat.set_model_hidden(%{model_id: model.id, hidden?: true}, actor: user)
      assert hid.id == fav.id
      assert hid.favorite? == true
      assert hid.hidden? == true

      {:ok, prefs} = Chat.my_model_preferences(actor: user)
      assert length(prefs) == 1
    end

    test "set_position stores an integer order", %{user: user, model: model} do
      {:ok, pref} = Chat.set_model_position(%{model_id: model.id, position: 3}, actor: user)
      assert pref.position == 3
    end
  end

  describe "validation" do
    test "rejects an internal model", %{user: user} do
      internal = generate(model(internal?: true))
      assert {:error, _} = Chat.set_model_favorite(%{model_id: internal.id, favorite?: true}, actor: user)
    end

    test "rejects an inactive model", %{user: user} do
      inactive = generate(model(active?: false))
      assert {:error, _} = Chat.set_model_favorite(%{model_id: inactive.id, favorite?: true}, actor: user)
    end
  end

  describe "scoping" do
    test "my_model_preferences returns only the actor's rows", %{user: user, model: model} do
      other = generate(user())
      {:ok, _} = Chat.set_model_favorite(%{model_id: model.id, favorite?: true}, actor: user)
      {:ok, _} = Chat.set_model_favorite(%{model_id: model.id, favorite?: true}, actor: other)

      {:ok, mine} = Chat.my_model_preferences(actor: user)
      assert length(mine) == 1
      assert hd(mine).user_id == user.id
    end
  end
end
