defmodule MagusWeb.SettingsLive.ApiTokensLive do
  @moduledoc """
  Settings page for managing Brain API personal access tokens.

  Users can list their tokens, generate new ones (one-time plaintext
  shown in a modal), and revoke existing ones.

  Security:
  - `:live_user_required` on_mount ensures only authenticated users reach this.
  - Every `handle_event/3` re-authorizes via Ash by passing the current user
    as `actor:`, so a forged `id` in `phx-value-id` cannot revoke another
    user's token.
  - `scope_from_string/1` whitelists `"write"` and `"read"`, so user input
    cannot drive `String.to_atom` (atom exhaustion DoS).
  - Plaintext token value is interpolated into JS via Phoenix.HTML.javascript_escape
    so a maliciously-crafted plaintext cannot break out of the JS string literal.
  """

  use MagusWeb, :live_view

  alias Magus.Accounts
  alias Magus.Workspaces
  alias MagusWeb.Layouts

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "API Tokens")
     |> assign(:current_path, "/settings/api-tokens")
     |> assign(:workspaces, list_workspaces(user))
     |> assign(:show_modal, false)
     |> assign(:new_token_plaintext, nil)
     |> assign(:form, build_form())
     |> stream_tokens(user)}
  end

  @impl true
  def handle_event("open_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:new_token_plaintext, nil)
     |> assign(:form, build_form())}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:new_token_plaintext, nil)}
  end

  def handle_event("create_token", %{"token" => attrs}, socket) do
    user = socket.assigns.current_user

    create_attrs = %{
      name: attrs["name"],
      scope: scope_from_string(attrs["scope"]),
      workspace_id: blank_to_nil(attrs["workspace_id"]),
      created_via: :settings
    }

    case Accounts.create_api_token(create_attrs, actor: user) do
      {:ok, %{token: token, plaintext: plaintext}} ->
        {:noreply,
         socket
         |> assign(:new_token_plaintext, plaintext)
         |> assign(:tokens_empty?, false)
         |> stream_insert(:tokens, token, at: 0)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not create token. Check the name and try again.")}
    end
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, token} <- Accounts.get_api_token(id, actor: user),
         {:ok, _} <- Accounts.revoke_api_token(token, actor: user) do
      remaining =
        case Accounts.list_api_tokens(actor: user) do
          {:ok, tokens} -> Enum.reject(tokens, & &1.revoked_at)
          _ -> []
        end

      {:noreply,
       socket
       |> stream_delete(:tokens, token)
       |> assign(:tokens_empty?, remaining == [])}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not revoke token.")}
    end
  end

  defp build_form do
    to_form(%{"name" => "", "scope" => "write", "workspace_id" => ""}, as: :token)
  end

  defp scope_from_string("write"), do: :write
  defp scope_from_string(_), do: :read

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp stream_tokens(socket, user) do
    tokens = list_tokens(user)

    socket
    |> assign(:tokens_empty?, tokens == [])
    |> stream(:tokens, tokens)
  end

  defp list_tokens(user) do
    case Accounts.list_api_tokens(actor: user) do
      {:ok, tokens} -> tokens
      _ -> []
    end
  end

  defp list_workspaces(user) do
    case Workspaces.my_workspaces(actor: user) do
      {:ok, workspaces} -> workspaces
      _ -> []
    end
  end

  defp js_escape(string) when is_binary(string) do
    Phoenix.HTML.javascript_escape(string)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="container mx-auto max-w-3xl py-8 px-4 space-y-6">
        <header class="flex items-center justify-between">
          <h1 class="text-2xl font-semibold">API Tokens</h1>
          <button class="btn btn-primary" phx-click="open_modal">Generate token</button>
        </header>

        <p class="text-base-content/70">
          Personal access tokens authenticate the <code>magus</code> CLI and MCP server.
          Each token is scoped to a single workspace and can be revoked at any time.
        </p>

        <div
          :if={@tokens_empty?}
          id="tokens-empty"
          class="p-6 text-center text-base-content/60 rounded border border-base-300"
        >
          No tokens yet. Click <em>Generate token</em> to create one.
        </div>

        <div
          :if={not @tokens_empty?}
          id="tokens"
          phx-update="stream"
          class="divide-y divide-base-300 rounded border border-base-300"
        >
          <div
            :for={{id, token} <- @streams.tokens}
            id={id}
            class="p-4 flex items-center justify-between gap-4"
          >
            <div class="space-y-1">
              <div class="font-medium">{token.name}</div>
              <div class="text-xs text-base-content/60 space-x-2">
                <span>{token.key_prefix}…</span>
                <span>·</span>
                <span>scope: {token.scope}</span>
                <span>·</span>
                <span>created via {token.created_via}</span>
                <span :if={token.last_used_at}>
                  · last used {Calendar.strftime(
                    DateTime.truncate(token.last_used_at, :second),
                    "%Y-%m-%d"
                  )}
                </span>
              </div>
            </div>
            <button
              class="btn btn-ghost btn-sm"
              phx-click="revoke_token"
              phx-value-id={token.id}
            >
              Revoke
            </button>
          </div>
        </div>

        <div :if={@show_modal} class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">New token</h3>

            <div :if={@new_token_plaintext} class="space-y-4">
              <div class="alert alert-warning">
                Copy this token now. It will not be shown again.
              </div>
              <div class="flex items-center gap-2">
                <input
                  type="text"
                  readonly
                  value={@new_token_plaintext}
                  class="input input-bordered flex-1 font-mono text-sm"
                />
                <button
                  class="btn btn-sm"
                  onclick={"navigator.clipboard.writeText('" <> js_escape(@new_token_plaintext) <> "')"}
                >
                  Copy
                </button>
              </div>
              <div class="modal-action">
                <button class="btn" phx-click="close_modal">Done</button>
              </div>
            </div>

            <.form
              :if={is_nil(@new_token_plaintext)}
              for={@form}
              id="new-token-form"
              phx-submit="create_token"
              class="space-y-4"
            >
              <.input
                field={@form[:name]}
                type="text"
                label="Name"
                placeholder="Claude Code on laptop"
                required
              />
              <.input
                field={@form[:workspace_id]}
                type="select"
                label="Workspace"
                options={[{"Personal", ""} | Enum.map(@workspaces, &{&1.name, &1.id})]}
              />
              <.input
                field={@form[:scope]}
                type="select"
                label="Permissions"
                options={[{"Read", "read"}, {"Read + Write", "write"}]}
              />
              <div class="modal-action">
                <button type="button" class="btn btn-ghost" phx-click="close_modal">Cancel</button>
                <button type="submit" class="btn btn-primary">Generate</button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
