defmodule MagusWeb.Admin.BulkCreateUsersLive do
  @moduledoc """
  Admin page for bulk-creating workshop/demo test accounts.

  Accounts are created with synthesised `username@magus.digital` emails,
  auto-generated easy-to-type passwords, no Stripe connection, an unlimited
  usage exemption, and an expiry date after which they are auto-deleted. The
  generated credentials are shown once so the admin can hand them out.
  """
  use MagusWeb, :live_view

  alias Magus.Accounts.TestAccounts
  alias MagusWeb.Layouts

  # Safety cap so a stray large number can't spawn thousands of accounts.
  @max_accounts 200
  @default_expiry_days 14

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Add Demo Users")
      |> assign(:current_path, "/admin/users")
      |> assign(:max_accounts, @max_accounts)
      |> assign(:mode, "generate")
      |> assign(:password_mode, "auto")
      |> assign(:shared_password, "")
      |> assign(:default_expires_on, Date.add(Date.utc_today(), @default_expiry_days))
      |> assign(:created, [])
      |> assign(:failed, [])
      |> assign(:csv, nil)
      |> assign(:submitted, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :mode, mode)}
  end

  @impl true
  def handle_event("set_password_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :password_mode, mode)}
  end

  @impl true
  def handle_event("generate_shared_password", _params, socket) do
    {:noreply, assign(socket, :shared_password, TestAccounts.generate_password())}
  end

  @impl true
  def handle_event("create", params, socket) do
    actor = socket.assigns.current_user
    language = parse_language(params["language"])
    expires_at = parse_expiry(params["expires_on"])

    with {:ok, usernames} <- collect_usernames(params),
         {:ok, items} <- apply_password_mode(usernames, params) do
      results =
        TestAccounts.create_many(items,
          actor: actor,
          language: language,
          expires_at: expires_at
        )

      {created, failed} =
        Enum.reduce(results, {[], []}, fn
          {:ok, cred}, {ok, err} -> {[cred | ok], err}
          {:error, info}, {ok, err} -> {ok, [info | err]}
        end)

      created = Enum.reverse(created)
      failed = Enum.reverse(failed)

      socket =
        socket
        |> assign(:submitted, true)
        |> assign(:created, created)
        |> assign(:failed, failed)
        |> assign(:csv, build_csv(created))
        |> put_flash(
          :info,
          "Created #{length(created)} account(s)" <>
            if(failed == [], do: "", else: ", #{length(failed)} failed")
        )

      {:noreply, socket}
    else
      {:error, message} ->
        # Keep the typed shared password so the admin doesn't have to retype it.
        {:noreply,
         socket
         |> assign(:shared_password, params["shared_password"] || socket.assigns.shared_password)
         |> put_flash(:error, message)}
    end
  end

  # Turns the collected usernames into the items create_many expects: bare
  # usernames (each gets its own generated password) or {username, password}
  # tuples when one shared password is used for the whole batch.
  defp apply_password_mode(usernames, %{"password_mode" => "shared"} = params) do
    password = String.trim(params["shared_password"] || "")

    if String.length(password) < 8 do
      {:error, "Enter a shared password of at least 8 characters."}
    else
      {:ok, Enum.map(usernames, &{&1, password})}
    end
  end

  defp apply_password_mode(usernames, _params), do: {:ok, usernames}

  # ---------------------------------------------------------------------------
  # Input parsing
  # ---------------------------------------------------------------------------

  defp collect_usernames(%{"mode" => "generate"} = params) do
    base = String.trim(params["base"] || "")
    count = parse_count(params["count"])

    cond do
      base == "" -> {:error, "Enter a base name (e.g. \"demo\")."}
      count <= 0 -> {:error, "Enter how many accounts to create."}
      count > @max_accounts -> {:error, "At most #{@max_accounts} accounts at a time."}
      true -> {:ok, TestAccounts.generate_usernames(base, count)}
    end
  end

  defp collect_usernames(%{"mode" => "list"} = params) do
    usernames =
      (params["usernames"] || "")
      |> String.split(["\n", "\r\n"], trim: true)
      |> Enum.map(&TestAccounts.sanitize_username/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      usernames == [] ->
        {:error, "Enter at least one username."}

      length(usernames) > @max_accounts ->
        {:error, "At most #{@max_accounts} accounts at a time."}

      true ->
        {:ok, usernames}
    end
  end

  defp collect_usernames(_), do: {:error, "Choose how to create the accounts."}

  defp parse_count(value) do
    case Integer.parse(to_string(value || "")) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_language("de"), do: :de
  defp parse_language(_), do: :en

  defp parse_expiry(value) do
    with value when is_binary(value) and value != "" <- value,
         {:ok, date} <- Date.from_iso8601(value),
         {:ok, naive} <- NaiveDateTime.new(date, ~T[23:59:59]) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ ->
        ~T[23:59:59]
        |> then(&NaiveDateTime.new!(Date.add(Date.utc_today(), @default_expiry_days), &1))
        |> DateTime.from_naive!("Etc/UTC")
    end
  end

  defp build_csv([]), do: nil

  defp build_csv(created) do
    header = "username,email,password,expires_at"

    rows =
      Enum.map(created, fn c ->
        "#{c.username},#{c.email},#{c.password},#{DateTime.to_iso8601(c.expires_at)}"
      end)

    Enum.join([header | rows], "\n")
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  # One option in a segmented toggle. Active = filled primary, inactive =
  # outlined — so it always reads as a clickable button, not a text link.
  attr :event, :string, required: true
  attr :value, :string, required: true
  attr :active, :string, required: true
  slot :inner_block, required: true

  defp seg(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-mode={@value}
      aria-pressed={@active == @value}
      class={[
        "btn btn-sm join-item normal-case",
        (@active == @value && "btn-primary") ||
          "btn-outline border-base-content/25 text-base-content/70 hover:text-base-content"
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # Numbered section heading for the multi-step form.
  attr :step, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  defp step_head(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <span class="flex-none w-7 h-7 rounded-full bg-primary/15 text-primary text-sm font-semibold flex items-center justify-center">
        {@step}
      </span>
      <div>
        <h2 class="font-semibold text-base-content leading-tight">{@title}</h2>
        <p :if={@subtitle} class="text-sm text-base-content/60">{@subtitle}</p>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6 max-w-3xl">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/admin/users"} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="lucide-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-base-content">Add Demo Users</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Bulk-create demo accounts under <span class="font-mono">@{TestAccounts.domain()}</span>.
              No Stripe, unlimited usage, auto-deleted at the expiry date.
            </p>
          </div>
        </div>

        <form
          phx-submit="create"
          class="card bg-base-200 border border-base-300 divide-y divide-base-300"
        >
          <input type="hidden" name="mode" value={@mode} />
          <input type="hidden" name="password_mode" value={@password_mode} />

          <%!-- Step 1: accounts --%>
          <section class="p-6 space-y-5">
            <.step_head
              step="1"
              title="Accounts"
              subtitle={"Logins are name@#{TestAccounts.domain()}"}
            />

            <div class="sm:pl-10 space-y-4">
              <div class="join">
                <.seg event="set_mode" value="generate" active={@mode}>Generate by count</.seg>
                <.seg event="set_mode" value="list" active={@mode}>Custom usernames</.seg>
              </div>

              <%= if @mode == "generate" do %>
                <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                  <label class="form-control sm:col-span-2">
                    <span class="label-text font-medium mb-1.5">Base name</span>
                    <label class="input input-bordered flex items-center gap-1 pr-3">
                      <input
                        type="text"
                        name="base"
                        value="demo"
                        placeholder="demo"
                        class="grow min-w-0"
                      />
                      <span class="text-base-content/40 whitespace-nowrap text-sm">1, 2, 3 …</span>
                    </label>
                    <span class="label-text-alt text-base-content/50 mt-1.5">
                      Creates demo1, demo2, … — existing names are skipped.
                    </span>
                  </label>
                  <label class="form-control">
                    <span class="label-text font-medium mb-1.5">How many</span>
                    <input
                      type="number"
                      name="count"
                      value="10"
                      min="1"
                      max={@max_accounts}
                      class="input input-bordered"
                    />
                  </label>
                </div>
              <% else %>
                <label class="form-control">
                  <span class="label-text font-medium mb-1.5">Usernames — one per line</span>
                  <textarea
                    name="usernames"
                    rows="6"
                    placeholder="anna\nben\nclara"
                    class="textarea textarea-bordered font-mono text-sm"
                  ></textarea>
                  <span class="label-text-alt text-base-content/50 mt-1.5">
                    Each becomes <span class="font-mono">name@{TestAccounts.domain()}</span>.
                  </span>
                </label>
              <% end %>
            </div>
          </section>

          <%!-- Step 2: password (its own field) --%>
          <section class="p-6 space-y-5">
            <.step_head
              step="2"
              title="Password"
              subtitle="How participants sign in — easy to type and read aloud."
            />

            <div class="sm:pl-10 space-y-4">
              <div class="join">
                <.seg event="set_password_mode" value="auto" active={@password_mode}>
                  Auto-generate (unique)
                </.seg>
                <.seg event="set_password_mode" value="shared" active={@password_mode}>
                  One shared password
                </.seg>
              </div>

              <%= if @password_mode == "shared" do %>
                <label class="form-control max-w-md">
                  <span class="label-text font-medium mb-1.5">Shared password</span>
                  <div class="join w-full">
                    <input
                      id="shared-password"
                      type="password"
                      name="shared_password"
                      value={@shared_password}
                      minlength="8"
                      autocomplete="off"
                      placeholder="at least 8 characters"
                      class="input input-bordered join-item grow font-mono"
                    />
                    <button
                      type="button"
                      id="toggle-shared-password"
                      phx-hook=".TogglePassword"
                      data-target="shared-password"
                      class="btn join-item btn-neutral"
                      aria-label="Show or hide password"
                      title="Show / hide"
                    >
                      <.icon name="lucide-eye" class="w-4 h-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="generate_shared_password"
                      class="btn join-item btn-neutral"
                      title="Generate a password"
                    >
                      <.icon name="lucide-shuffle" class="w-4 h-4" />
                    </button>
                  </div>
                  <span class="label-text-alt text-base-content/50 mt-1.5">
                    Everyone uses this one password — easiest to announce to a room.
                  </span>
                </label>
              <% else %>
                <div class="flex items-center gap-2 text-sm text-base-content/70 rounded-lg bg-base-100 border border-base-300 px-3 py-2.5 w-fit">
                  <.icon name="lucide-check" class="w-4 h-4 text-success flex-none" />
                  Each account gets its own memorable password, shown after you create them.
                </div>
              <% end %>
            </div>
          </section>

          <%!-- Step 3: options --%>
          <section class="p-6 space-y-5">
            <.step_head step="3" title="Options" />

            <div class="sm:pl-10">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <label class="form-control">
                  <span class="label-text font-medium mb-1.5">Language</span>
                  <select name="language" class="select select-bordered">
                    <option value="en">English</option>
                    <option value="de">Deutsch</option>
                  </select>
                </label>
                <label class="form-control">
                  <span class="label-text font-medium mb-1.5">Delete accounts on</span>
                  <input
                    type="date"
                    name="expires_on"
                    value={Date.to_iso8601(@default_expires_on)}
                    class="input input-bordered"
                  />
                  <span class="label-text-alt text-base-content/50 mt-1.5">
                    Accounts and their data are permanently deleted on this date.
                  </span>
                </label>
              </div>
            </div>
          </section>

          <%!-- Action bar: primary action pinned bottom-right --%>
          <div class="flex justify-end items-center gap-3 px-6 py-4 bg-base-300/40">
            <.link navigate={~p"/admin/users"} class="btn btn-ghost">Cancel</.link>
            <button type="submit" class="btn btn-primary" phx-disable-with="Creating…">
              <.icon name="lucide-user-plus" class="w-4 h-4" /> Create accounts
            </button>
          </div>
        </form>

        <%= if @submitted do %>
          <div class="space-y-4">
            <%= if @created != [] do %>
              <div class="card bg-base-200 border border-base-300 overflow-hidden">
                <div class="flex items-center justify-between p-4 border-b border-base-300">
                  <h2 class="font-semibold">
                    {length(@created)} account(s) created
                  </h2>
                  <div class="flex gap-2">
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-hook=".CopyCsv"
                      id="copy-csv"
                      data-csv={@csv}
                    >
                      <.icon name="lucide-copy" class="w-4 h-4" /> Copy CSV
                    </button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-hook=".DownloadCsv"
                      id="download-csv"
                      data-csv={@csv}
                    >
                      <.icon name="lucide-download" class="w-4 h-4" /> Download CSV
                    </button>
                  </div>
                </div>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Login email</th>
                        <th>Password</th>
                        <th>Expires</th>
                        <th>Unlimited</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={c <- @created}>
                        <td class="font-mono">{c.email}</td>
                        <td class="font-mono">{c.password}</td>
                        <td>{Calendar.strftime(c.expires_at, "%Y-%m-%d")}</td>
                        <td>
                          <span :if={c.exempt} class="badge badge-success badge-sm">yes</span>
                          <span :if={!c.exempt} class="badge badge-warning badge-sm">no</span>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            <% end %>

            <%= if @failed != [] do %>
              <div class="card bg-base-200 border border-error/40 overflow-hidden">
                <div class="p-4 border-b border-error/40">
                  <h2 class="font-semibold text-error">{length(@failed)} failed</h2>
                </div>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Email</th>
                        <th>Reason</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={f <- @failed}>
                        <td class="font-mono">{f.email}</td>
                        <td class="text-base-content/70">{f.reason}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TogglePassword">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const input = document.getElementById(this.el.dataset.target)
              if (!input) return
              input.type = input.type === "password" ? "text" : "password"
            })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyCsv">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              navigator.clipboard.writeText(this.el.dataset.csv || "")
            })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DownloadCsv">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const blob = new Blob([this.el.dataset.csv || ""], { type: "text/csv" })
              const url = URL.createObjectURL(blob)
              const a = document.createElement("a")
              a.href = url
              a.download = "test-accounts.csv"
              a.click()
              URL.revokeObjectURL(url)
            })
          }
        }
      </script>
    </Layouts.admin>
    """
  end
end
