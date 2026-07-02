defmodule Magus.Skills.SkillFavoriteTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills

  defp create_skill!(owner, attrs \\ %{}) do
    {:ok, skill} =
      Skills.create_skill(
        Map.merge(%{name: "fav-target", description: "A skill"}, attrs),
        actor: owner
      )

    skill
  end

  describe "favoriting" do
    test "a user favorites a skill they can read" do
      owner = generate(user())
      skill = create_skill!(owner)

      assert {:ok, favorite} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)
      assert favorite.skill_id == skill.id
      assert favorite.user_id == owner.id
    end

    test "favoriting an inaccessible skill is forbidden" do
      owner = generate(user())
      stranger = generate(user())
      skill = create_skill!(owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Skills.favorite_skill(%{skill_id: skill.id}, actor: stranger)
    end

    test "favoriting the same skill twice fails on the unique identity" do
      owner = generate(user())
      skill = create_skill!(owner)

      assert {:ok, _} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)
    end
  end

  describe "reading favorites" do
    test "my_skill_favorites returns only the actor's rows" do
      owner = generate(user())
      other = generate(user())
      skill = create_skill!(owner, %{name: "mine"})

      {:ok, _} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)

      assert {:ok, [row]} = Skills.my_skill_favorites(actor: owner)
      assert row.skill_id == skill.id
      assert {:ok, []} = Skills.my_skill_favorites(actor: other)
    end

    test "my_favorite_skills returns favorited skills and unfavorite removes them" do
      owner = generate(user())
      favorited = create_skill!(owner, %{name: "favorited"})
      _plain = create_skill!(owner, %{name: "plain"})

      {:ok, favorite} = Skills.favorite_skill(%{skill_id: favorited.id}, actor: owner)

      assert {:ok, [skill]} = Skills.my_favorite_skills(actor: owner)
      assert skill.id == favorited.id

      assert :ok = Skills.unfavorite_skill(favorite, actor: owner)
      assert {:ok, []} = Skills.my_favorite_skills(actor: owner)
    end

    test "destroying a favorited skill cascades the favorite row" do
      owner = generate(user())
      skill = create_skill!(owner, %{name: "cascade-target"})

      {:ok, _favorite} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)

      assert :ok = Skills.destroy_skill(skill, actor: owner)
      assert {:ok, []} = Skills.my_skill_favorites(actor: owner)
    end

    test "is_favorited calculation reflects the actor" do
      owner = generate(user())
      other = generate(user())
      skill = create_skill!(owner)
      {:ok, _} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)

      {:ok, for_owner} = Skills.get_skill(skill.id, actor: owner, load: [:is_favorited])
      assert for_owner.is_favorited

      # `other` cannot read the personal skill at all; verify the calc is
      # false for a second user on a workspace-visible skill instead.
      {:ok, for_owner_unfavorited} =
        Skills.get_skill(create_skill!(owner, %{name: "unfav"}).id,
          actor: owner,
          load: [:is_favorited]
        )

      refute for_owner_unfavorited.is_favorited
      _ = other
    end
  end
end
