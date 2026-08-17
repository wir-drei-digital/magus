defmodule MagusWeb.Admin.UserDetailLiveTest do
  use MagusWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Magus.Generators
  import Swoosh.TestAssertions

  require Ash.Query

  alias AshAuthentication.Plug.Helpers

  setup %{conn: conn} do
    tag = "udetail#{System.unique_integer([:positive])}"
    admin = make_admin(generate(user(email: "#{tag}-admin@test.com")))

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(admin)

    %{conn: conn, admin: admin, tag: tag}
  end

  defp make_admin(user) do
    user
    |> Ash.Changeset.for_update(:update_profile, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:is_admin, true)
    |> Ash.update!(authorize?: false)
  end

  # Generator users are created unconfirmed (their signup emits a
  # confirmation email into the test mailbox — drain before asserting on
  # mail). confirm!/1 flips one to confirmed for the negative test.
  defp confirm!(user) do
    Magus.Repo.update_all(
      from(u in "users", where: u.id == type(^user.id, :binary_id)),
      set: [confirmed_at: DateTime.utc_now()]
    )

    reload!(user)
  end

  defp drain_mailbox do
    receive do
      {:email, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp reload!(user), do: Ash.reload!(user, authorize?: false)

  defp user_exists?(id) do
    Magus.Accounts.User
    |> Ash.Query.filter(id == ^id)
    |> Ash.exists?(authorize?: false)
  end

  describe "confirm email" do
    test "button shows only for unconfirmed users and confirms without sending mail", %{
      conn: conn,
      tag: tag
    } do
      user = generate(user(email: "#{tag}-unconfirmed@test.com"))
      assert is_nil(user.confirmed_at)

      {:ok, lv, html} = live(conn, ~p"/admin/users/#{user.id}")
      assert html =~ "Unconfirmed"
      assert html =~ "Confirm email"

      # Setup created two users, each of whose signup sent a confirmation
      # email; clear those so the assertion below sees only what the admin
      # action produces.
      drain_mailbox()

      html = lv |> element("button", "Confirm email") |> render_click()

      assert html =~ "Email confirmed for"
      refute reload!(user).confirmed_at |> is_nil()
      assert_no_email_sent()
    end

    test "no confirm button for already-confirmed users", %{conn: conn, tag: tag} do
      user = confirm!(generate(user(email: "#{tag}-confirmed@test.com")))
      refute is_nil(user.confirmed_at)

      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{user.id}")
      refute html =~ "Confirm email"
    end

    test "the action itself is forbidden for non-admin actors", %{tag: tag} do
      target = generate(user(email: "#{tag}-target@test.com"))
      other = generate(user(email: "#{tag}-other@test.com"))

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(
                 Ash.Changeset.for_update(target, :admin_confirm_email, %{}, actor: other)
               )
    end
  end

  describe "delete user" do
    test "danger zone renders for regular users and deletes the account", %{
      conn: conn,
      tag: tag
    } do
      user = generate(user(email: "#{tag}-victim@test.com"))

      {:ok, lv, html} = live(conn, ~p"/admin/users/#{user.id}")
      assert html =~ "Danger Zone"

      lv |> element("button[phx-click=delete_user]") |> render_click()

      flash = assert_redirect(lv, ~p"/admin/users")
      assert flash["info"] =~ "Deleted account"
      refute user_exists?(user.id)
    end

    test "admin accounts get no danger zone and the handler refuses them", %{
      conn: conn,
      tag: tag
    } do
      other_admin = make_admin(generate(user(email: "#{tag}-admin2@test.com")))

      {:ok, lv, html} = live(conn, ~p"/admin/users/#{other_admin.id}")
      refute html =~ "Danger Zone"

      # Direct event injection past the missing button must also refuse.
      html = render_click(lv, "delete_user", %{})
      assert html =~ "can&#39;t be deleted here" or html =~ "can't be deleted here"
      assert user_exists?(other_admin.id)
    end
  end
end
