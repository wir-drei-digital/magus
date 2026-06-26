defmodule MagusWeb.Cli.CliAuthorizeLive do
  @moduledoc """
  CLI authorization screen for the `magus login` localhost-callback flow.

  The CLI opens this page with `?callback=http://127.0.0.1:<port>&state=...`.
  After the user approves, the page generates an `ApiToken` and redirects
  the browser back to the callback with `?token=<plaintext>&state=<echo>`.

  Security:
  - `:live_user_required` on_mount ensures only authenticated users reach this.
  - `validate_callback/1` rejects anything that isn't `http://127.0.0.1:*` or
    `http://localhost:*`, preventing token exfiltration to attacker hosts.
  - `scope_from_string/1` whitelists `"write"` and `"read"`, so user input
    cannot drive `String.to_atom` (atom exhaustion DoS).
  - Token creation is authorized via Ash policies using the current user as
    actor, so authorization is re-checked on every submit.
  """

  use MagusWeb, :live_view

  alias Magus.Accounts
  alias Magus.Workspaces
  alias MagusWeb.Layouts

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, _session, socket) do
    case validate_callback(params["callback"]) do
      {:ok, callback} ->
        user = socket.assigns.current_user

        socket =
          socket
          |> assign(:page_title, "Authorize CLI")
          |> assign(:callback, callback)
          |> assign(:state, params["state"] || "")
          |> assign(:workspaces, list_workspaces(user))
          |> assign(:form, build_form())

        {:ok, socket}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid CLI callback URL.")
         |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_event("submit", %{"token" => attrs}, socket) do
    user = socket.assigns.current_user

    workspace_id =
      case attrs["workspace_id"] do
        nil -> nil
        "" -> nil
        id -> id
      end

    create_attrs = %{
      name: attrs["name"],
      scope: scope_from_string(attrs["scope"]),
      workspace_id: workspace_id,
      created_via: :cli_login
    }

    case Accounts.create_api_token(create_attrs, actor: user) do
      {:ok, %{plaintext: plaintext}} ->
        url =
          socket.assigns.callback
          |> URI.parse()
          |> append_query(token: plaintext, state: socket.assigns.state)
          |> URI.to_string()

        {:noreply, redirect(socket, external: url)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not create token. Check the name and try again.")}
    end
  end

  defp build_form do
    to_form(%{"name" => "", "scope" => "write", "workspace_id" => ""}, as: :token)
  end

  # Whitelist of valid scope strings. NEVER use String.to_atom on user input.
  defp scope_from_string("write"), do: :write
  defp scope_from_string(_), do: :read

  defp list_workspaces(user) do
    case Workspaces.my_workspaces(actor: user) do
      {:ok, workspaces} -> workspaces
      {:error, _} -> []
    end
  end

  defp validate_callback(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "localhost"] -> {:ok, url}
      _ -> :error
    end
  end

  defp validate_callback(_), do: :error

  defp append_query(%URI{} = uri, params) do
    existing =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop(["token", "state"])

    merged = Map.merge(existing, Map.new(params, fn {k, v} -> {to_string(k), v} end))
    %{uri | query: URI.encode_query(merged)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="container mx-auto max-w-xl py-12 px-4">
        <h1 class="text-2xl font-semibold mb-2">Magus CLI wants access</h1>
        <p class="text-base-content/70 mb-6">
          Approving will create a personal access token bound to your account and
          send it to the CLI on your machine. You can revoke it any time from Settings.
        </p>

        <.form for={@form} id="cli-authorize-form" phx-submit="submit" class="space-y-4">
          <div>
            <label class="label" for="token_name">Name</label>
            <.input
              field={@form[:name]}
              type="text"
              placeholder="Claude Code on laptop"
              required
            />
          </div>

          <div>
            <label class="label" for="token_workspace_id">Workspace</label>
            <.input
              field={@form[:workspace_id]}
              type="select"
              options={[{"Personal", ""} | Enum.map(@workspaces, &{&1.name, &1.id})]}
            />
          </div>

          <div>
            <label class="label">Permissions</label>
            <.input
              field={@form[:scope]}
              type="select"
              options={[{"Read", "read"}, {"Read + Write", "write"}]}
            />
          </div>

          <div class="flex gap-2 pt-4">
            <button type="submit" class="btn btn-primary">Approve</button>
            <.link navigate="/" class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
