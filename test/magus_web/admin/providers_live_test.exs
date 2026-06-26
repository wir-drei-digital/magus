defmodule MagusWeb.Admin.ProvidersLiveTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers

  setup %{conn: conn} do
    # Seeded providers from the InternalizeExtras data migration live in the
    # base test connection (openrouter, publicai, ...). Clear the catalog so
    # tests start from a known-empty provider set.
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

  test "lists configured providers", %{conn: conn} do
    Magus.Models.create_provider!(
      %{name: "OpenRouter", slug: "openrouter", req_llm_id: "openrouter"},
      authorize?: false
    )

    {:ok, _view, html} = live(conn, ~p"/admin/providers")
    assert html =~ ~s(data-test-provider="openrouter")
  end

  test "creates a custom provider through the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/providers/new")

    view
    |> form("#provider-form",
      form: %{
        name: "Local vLLM",
        slug: "local_vllm",
        req_llm_id: "openai_compatible",
        base_url: "http://localhost:8000/v1",
        api_key: "sk-local"
      }
    )
    |> render_submit()

    assert {:ok, provider} = Magus.Models.get_provider_by_slug("local_vllm")
    assert provider.api_key == "sk-local"
  end

  test "stored api_key is never rendered", %{conn: conn} do
    Magus.Models.create_provider!(
      %{name: "P", slug: "secret_p", req_llm_id: "openrouter", api_key: "sk-leakcheck"},
      authorize?: false
    )

    {:ok, _view, html} = live(conn, ~p"/admin/providers")
    refute html =~ "sk-leakcheck"

    {:ok, _view, edit_html} = live(conn, ~p"/admin/providers/#{provider_id("secret_p")}/edit")
    refute edit_html =~ "sk-leakcheck"
  end

  test "blank api_key on edit preserves the stored key", %{conn: conn} do
    Magus.Models.create_provider!(
      %{name: "Keep", slug: "keep_key", req_llm_id: "openrouter", api_key: "sk-original"},
      authorize?: false
    )

    {:ok, view, _html} = live(conn, ~p"/admin/providers/#{provider_id("keep_key")}/edit")

    view
    |> form("#provider-form",
      form: %{
        name: "Keep Renamed",
        base_url: "",
        api_key: ""
      }
    )
    |> render_submit()

    {:ok, provider} = Magus.Models.get_provider_by_slug("keep_key")
    assert provider.name == "Keep Renamed"
    assert provider.api_key == "sk-original"
  end

  test "updates the stored api_key when a new value is supplied", %{conn: conn} do
    Magus.Models.create_provider!(
      %{name: "Rotate", slug: "rotate_key", req_llm_id: "openrouter", api_key: "sk-old"},
      authorize?: false
    )

    {:ok, view, _html} = live(conn, ~p"/admin/providers/#{provider_id("rotate_key")}/edit")

    view
    |> form("#provider-form",
      form: %{
        name: "Rotate",
        api_key: "sk-new"
      }
    )
    |> render_submit()

    {:ok, provider} = Magus.Models.get_provider_by_slug("rotate_key")
    assert provider.api_key == "sk-new"
  end

  test "toggle_enabled flips the provider's enabled? flag", %{conn: conn} do
    Magus.Models.create_provider!(
      %{name: "Toggle", slug: "toggle_p", req_llm_id: "openrouter", enabled?: true},
      authorize?: false
    )

    {:ok, view, _html} = live(conn, ~p"/admin/providers")

    view
    |> element(~s([data-test-toggle="toggle_p"]))
    |> render_click()

    {:ok, provider} = Magus.Models.get_provider_by_slug("toggle_p")
    refute provider.enabled?

    # Toggling again flips it back.
    view
    |> element(~s([data-test-toggle="toggle_p"]))
    |> render_click()

    {:ok, provider} = Magus.Models.get_provider_by_slug("toggle_p")
    assert provider.enabled?
  end

  test "test_connection renders an error into data-test-health on transport failure",
       %{conn: conn} do
    # openai_compatible + a stored key drives HealthCheck.test_provider past
    # the auth/base-url guards into a real Req request. Pointing at a closed
    # port (127.0.0.1:1) yields a fast transport error, deterministically with
    # no network dependency. The async task runs via async_nolink, so the
    # error must arrive through the {ref, result} handler.
    Magus.Models.create_provider!(
      %{
        name: "Dead",
        slug: "dead_provider",
        req_llm_id: "openai_compatible",
        base_url: "http://127.0.0.1:1/v1",
        api_key: "sk-test"
      },
      authorize?: false
    )

    {:ok, view, _html} = live(conn, ~p"/admin/providers")

    view
    |> element(~s([data-test-connection="dead_provider"]))
    |> render_click()

    # Poll until the async result lands in the health cell.
    rendered =
      Enum.find_value(1..50, fn _ ->
        Process.sleep(20)
        html = render(view)

        if html =~ ~s(data-test-health="dead_provider") and html =~ "text-error" do
          html
        end
      end)

    assert rendered, "expected an error to render into data-test-health within timeout"
  end

  test "non-admin user cannot access", %{conn: _conn} do
    non_admin = generate(user(is_admin: false))

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(non_admin)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/providers")
    assert to == ~p"/"
  end

  defp provider_id(slug) do
    {:ok, p} = Magus.Models.get_provider_by_slug(slug)
    p.id
  end
end
