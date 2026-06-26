defmodule MagusWeb.Admin.ModelsLiveIndexTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers
  alias Magus.Chat.Model

  setup %{conn: conn} do
    # Seeded providers/internal models live in the base test connection; start
    # from a known-empty catalog so row counts are deterministic.
    Magus.DataCase.clear_catalog!()

    admin = make_admin(generate(user()))

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(admin)

    %{conn: conn, admin: admin}
  end

  defp make_admin(user) do
    {:ok, admin} =
      user
      |> Ash.Changeset.for_update(:update_profile, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:is_admin, true)
      |> Ash.update(authorize?: false)

    admin
  end

  defp create_model(attrs) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{name: "Model #{n}", key: "test/model-#{n}", provider: "test"},
        Map.new(attrs)
      )

    Model
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  # Ordered list of model ids rendered in the table (one per row).
  defp row_ids(html) do
    ~r/data-test-delete-confirm="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(&List.last/1)
  end

  defp on_page?(html, model), do: model.id in row_ids(html)

  describe "status filter" do
    test "narrows to active / disabled", %{conn: conn} do
      active = create_model(%{active?: true})
      disabled = create_model(%{active?: false})

      {:ok, _view, html} = live(conn, ~p"/admin/models")
      assert on_page?(html, active)
      assert on_page?(html, disabled)

      {:ok, _view, html} = live(conn, ~p"/admin/models?status=active")
      assert on_page?(html, active)
      refute on_page?(html, disabled)

      {:ok, _view, html} = live(conn, ~p"/admin/models?status=disabled")
      refute on_page?(html, active)
      assert on_page?(html, disabled)
    end
  end

  describe "provider filter" do
    test "keeps only the matching displayed provider", %{conn: conn} do
      anthropic = create_model(%{provider: "Anthropic"})
      openai = create_model(%{provider: "OpenAI"})

      {:ok, _view, html} = live(conn, ~p"/admin/models?provider=Anthropic")
      assert on_page?(html, anthropic)
      refute on_page?(html, openai)
    end
  end

  describe "capability filter" do
    test "keeps only models with the capability", %{conn: conn} do
      reasoning = create_model(%{supports_reasoning?: true})
      plain = create_model(%{supports_reasoning?: false})

      {:ok, _view, html} = live(conn, ~p"/admin/models?caps=reasoning")
      assert on_page?(html, reasoning)
      refute on_page?(html, plain)
    end

    test "image capability comes from output modalities", %{conn: conn} do
      image = create_model(%{output_modalities: ["image"]})
      text = create_model(%{output_modalities: ["text"]})

      {:ok, _view, html} = live(conn, ~p"/admin/models?caps=image")
      assert on_page?(html, image)
      refute on_page?(html, text)
    end
  end

  describe "sorting" do
    test "name direction reorders the rows", %{conn: conn} do
      a = create_model(%{name: "AAA First"})
      z = create_model(%{name: "ZZZ Last"})

      {:ok, _view, html} = live(conn, ~p"/admin/models?sort=name&dir=asc")
      assert row_ids(html) |> Enum.take_while(&(&1 != z.id)) |> Enum.member?(a.id)

      {:ok, _view, html} = live(conn, ~p"/admin/models?sort=name&dir=desc")
      assert row_ids(html) |> Enum.take_while(&(&1 != a.id)) |> Enum.member?(z.id)
    end

    test "a sort header links carry the sort params", %{conn: conn} do
      create_model(%{})
      {:ok, _view, html} = live(conn, ~p"/admin/models")
      # Name header is sortable and currently active ascending by default.
      assert html =~ ~s(data-test-sort="name")
      assert html =~ ~s(data-test-sort="usage")
    end
  end

  describe "pagination" do
    test "caps at 50 rows per page", %{conn: conn} do
      for _ <- 1..51, do: create_model(%{})

      {:ok, _view, html} = live(conn, ~p"/admin/models")
      assert length(row_ids(html)) == 50
      assert html =~ "data-test-models-pagination"
      assert html =~ "data-test-page-next"
      assert html =~ "51 models"

      {:ok, _view, html} = live(conn, ~p"/admin/models?page=2")
      assert length(row_ids(html)) == 1
    end

    test "no pager when a single page", %{conn: conn} do
      create_model(%{})
      {:ok, _view, html} = live(conn, ~p"/admin/models")
      refute html =~ "data-test-page-next"
      assert html =~ "1 model"
    end
  end

  describe "clear filters" do
    test "clear link appears only when a filter is active", %{conn: conn} do
      create_model(%{})

      {:ok, _view, html} = live(conn, ~p"/admin/models")
      refute html =~ "data-test-clear-filters"

      {:ok, _view, html} = live(conn, ~p"/admin/models?status=active")
      assert html =~ "data-test-clear-filters"
    end
  end
end
