defmodule MagusWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Lucide Icons](https://lucide.dev) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="lucide-info" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="lucide-alert-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="lucide-x" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"
  attr :hint, :string, default: nil, doc: "hint text shown below the input"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label class="flex flex-col w-full">
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            "w-full",
            @class || "textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <p :if={@hint} class="text-xs text-base-content/50 mt-1.5">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="lucide-alert-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a card container for grouping related content on settings-style pages.

  ## Examples

      <.content_card title="Profile" icon="lucide-user">
        <p>Card content here</p>
      </.content_card>

      <.content_card title="Instructions" icon="lucide-file-text" subtitle="Define the agent's behavior.">
        <textarea />
      </.content_card>
  """
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  def content_card(assigns) do
    ~H"""
    <div class="bg-base-200 border border-base-300 rounded-xl p-5 shadow-sm">
      <h2 class="text-lg font-semibold text-base-content mb-1 flex items-center gap-2">
        <.icon :if={@icon} name={@icon} class="w-5 h-5" />
        {@title}
      </h2>
      <p :if={@subtitle} class="text-sm text-base-content/60 mb-4">{@subtitle}</p>
      <div class={unless @subtitle, do: "mt-3"}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a page layout with a left sidebar navigation on desktop
  and a horizontal scrollable nav bar on mobile.

  Each nav item is a map with `:label`, `:icon`, and `:active?` keys, plus either:
  - `:href` for link-based navigation (LiveView `navigate`)
  - `:on_click` and `:click_value` for event-based switching (e.g., form tabs)

  ## Examples

      <%!-- Link-based navigation --%>
      <.page_with_sidebar_nav nav_items={[
        %{label: "Profile", icon: "lucide-user", href: "/settings", active?: true},
        %{label: "Preferences", icon: "lucide-sliders", href: "/settings/preferences", active?: false}
      ]}>
        <p>Page content here</p>
      </.page_with_sidebar_nav>

      <%!-- Event-based navigation --%>
      <.page_with_sidebar_nav nav_items={[
        %{label: "General", icon: "lucide-user", on_click: "switch_tab", click_value: "general", active?: true},
        %{label: "Model", icon: "lucide-wrench", on_click: "switch_tab", click_value: "model", active?: false}
      ]}>
        <p>Tab content here</p>
      </.page_with_sidebar_nav>
  """
  attr :nav_items, :list, required: true
  slot :inner_block, required: true

  def page_with_sidebar_nav(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row gap-6 w-full">
      <%!-- Mobile: horizontal scrollable nav --%>
      <nav class="md:hidden flex gap-1 overflow-x-auto pb-2 border-b border-base-300 -mx-4 px-4">
        <.sidebar_nav_item
          :for={item <- @nav_items}
          item={item}
          icon_class="w-4 h-4"
          class="flex items-center gap-2 px-3 py-2 text-sm font-medium rounded-lg whitespace-nowrap transition-colors"
        />
      </nav>

      <%!-- Desktop: sticky left sidebar nav --%>
      <nav class="hidden md:block w-56 shrink-0">
        <div class="sticky top-20">
          <ul class="space-y-1">
            <li :for={item <- @nav_items}>
              <.sidebar_nav_item
                item={item}
                icon_class="w-5 h-5"
                class="flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-lg transition-colors"
              />
            </li>
          </ul>
        </div>
      </nav>

      <%!-- Main content area --%>
      <div class="flex-1 min-w-0">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :class, :string, required: true
  attr :icon_class, :string, default: "w-5 h-5"

  defp sidebar_nav_item(%{item: %{href: _}} = assigns) do
    ~H"""
    <.link
      navigate={@item.href}
      class={[
        @class,
        if(@item[:active?],
          do: "bg-primary/10 text-primary",
          else: "text-base-content/70 hover:text-base-content hover:bg-base-300/50"
        )
      ]}
    >
      <.icon name={@item.icon} class={@icon_class} />
      {@item.label}
    </.link>
    """
  end

  defp sidebar_nav_item(%{item: %{on_click: _}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@item.on_click}
      phx-value-tab={@item.click_value}
      class={[
        @class,
        "w-full text-left cursor-pointer",
        if(@item[:active?],
          do: "bg-primary/10 text-primary",
          else: "text-base-content/70 hover:text-base-content hover:bg-base-300/50"
        )
      ]}
    >
      <.icon name={@item.icon} class={@icon_class} />
      {@item.label}
    </button>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Lucide](https://lucide.dev) icon.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from `node_modules/lucide-static/icons` and bundled within
  your compiled app.css by the plugin in `assets/vendor/lucide.js`.

  ## Examples

      <.icon name="lucide-x" />
      <.icon name="lucide-refresh-cw" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "lucide-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  def icon(%{name: "magus-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  def icon(assigns) do
    ~H"""
    <span class={@class} aria-hidden="true" />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(MagusWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(MagusWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Renders a search input with a magnifying glass icon.

  ## Examples

      <.search_input name="query" value={@search_query} placeholder="Search..." />
      <.search_input name="query" value={@search_query} size="sm" />
  """
  attr :name, :string, default: "query"
  attr :value, :string, default: ""
  attr :placeholder, :string, default: "Search..."
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :debounce, :string, default: "300"
  attr :class, :string, default: nil

  def search_input(assigns) do
    input_class =
      case assigns.size do
        "sm" -> "input input-bordered input-sm w-full pl-9"
        "md" -> "input input-bordered w-full pl-10"
      end

    icon_class =
      case assigns.size do
        "sm" -> "w-4 h-4"
        "md" -> "w-5 h-5"
      end

    assigns =
      assigns
      |> assign(:input_class, input_class)
      |> assign(:icon_class, icon_class)

    ~H"""
    <div class={@class || "relative"}>
      <.icon
        name="lucide-search"
        class={["absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40 z-10", @icon_class]}
      />
      <input
        type="text"
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class={@input_class}
        phx-debounce={@debounce}
      />
    </div>
    """
  end

  @doc """
  Renders a list card with an icon, title, subtitle, metadata, and optional badge.

  Used for consistent styling across search results, conversation history, and jobs lists.

  ## Examples

      <.list_card navigate={~p"/chat/\#{conv.id}"} icon="lucide-messages-square">
        <:title>{conv.title}</:title>
        <:subtitle>{conv.preview}</:subtitle>
        <:badge>Active</:badge>
        <:meta>
          <span>Jan 12, 2025</span>
          <span>5 messages</span>
        </:meta>
      </.list_card>
  """
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :icon_class, :string, default: "w-5 h-5"

  slot :title, required: true
  slot :subtitle
  slot :badge
  slot :meta

  def list_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "group block bg-wb-surface border border-base-300 rounded-xl overflow-x-auto",
        "p-5 shadow-sm hover:shadow-md hover:border-primary/30 transition-all"
      ]}
    >
      <div class="flex items-start gap-4">
        <div class="flex-shrink-0 w-10 h-10 bg-wb-surface-2 rounded-lg flex items-center justify-center text-base-content/60 group-hover:bg-primary/10 group-hover:text-primary transition-colors">
          <.icon name={@icon} class={@icon_class} />
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 mb-1">
            <h3 class="font-medium text-base-content truncate group-hover:text-primary transition-colors">
              {render_slot(@title)}
            </h3>
            {render_slot(@badge)}
          </div>
          <p :if={@subtitle != []} class="text-sm text-base-content/60 line-clamp-2">
            {render_slot(@subtitle)}
          </p>
          <div
            :if={@meta != []}
            class="flex gap-x-4 gap-y-1 mt-2 text-xs text-base-content/50 overflow-x-auto"
          >
            {render_slot(@meta)}
          </div>
        </div>
        <.icon
          name="lucide-chevron-right"
          class="w-5 h-5 text-base-content/30 group-hover:text-primary transition-colors shrink-0"
        />
      </div>
    </.link>
    """
  end

  @doc """
  Renders a user avatar with image support and fallback to initials.

  ## Examples

      <.user_avatar user={@user} />
      <.user_avatar user={@user} size="lg" />
      <.user_avatar user={@user} size="sm" class="ring ring-primary" />

  ## Sizes

  - `xs` - 24x24px (w-6 h-6)
  - `sm` - 32x32px (w-8 h-8)
  - `md` - 40x40px (w-10 h-10) - default
  - `lg` - 80x80px (w-20 h-20)

  """
  attr :user, :map, required: true, doc: "user map with optional avatar_path and email fields"
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :class, :string, default: nil, doc: "additional CSS classes"

  def user_avatar(assigns) do
    {size_class, text_class} =
      case assigns.size do
        "xs" -> {"w-6 h-6", "text-[10px]"}
        "sm" -> {"w-8 h-8", "text-xs"}
        "md" -> {"w-10 h-10", "text-sm"}
        "lg" -> {"w-20 h-20", "text-2xl"}
        _ -> {"w-10 h-10", "text-sm"}
      end

    avatar_url = get_avatar_url(assigns.user)
    initials = get_user_initials(assigns.user)

    assigns =
      assigns
      |> assign(:size_class, size_class)
      |> assign(:text_class, text_class)
      |> assign(:avatar_url, avatar_url)
      |> assign(:initials, initials)

    ~H"""
    <%= if @avatar_url do %>
      <img
        src={@avatar_url}
        class={[
          @size_class,
          "rounded-full object-cover border border-base-300 flex-shrink-0",
          @class
        ]}
        alt="Avatar"
      />
    <% else %>
      <div class={[
        @size_class,
        "rounded-full bg-gradient-to-br from-primary/20 to-secondary/20",
        "flex items-center justify-center border border-base-300 flex-shrink-0",
        @class
      ]}>
        <span class={[@text_class, "font-medium text-base-content leading-none"]}>
          {@initials}
        </span>
      </div>
    <% end %>
    """
  end

  defp get_avatar_url(%{avatar_path: nil}), do: nil

  defp get_avatar_url(%{avatar_path: path}) when is_binary(path) do
    case Magus.Files.Storage.get_url(path) do
      {:ok, url} -> url
      _ -> nil
    end
  end

  defp get_avatar_url(_), do: nil

  defp get_user_initials(%{email: email}) when is_binary(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp get_user_initials(%{email: email}) when not is_nil(email) do
    email
    |> to_string()
    |> String.split("@")
    |> List.first()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp get_user_initials(_), do: "?"

  @doc """
  Renders a header dropdown button with a popup panel.

  Supports two interaction modes controlled by the `open` attr:

  - **CSS mode** (default, `open` not set): Uses DaisyUI focus-based dropdown.
    Works everywhere including dead views.
  - **Live mode** (`open` set to boolean): Uses `phx-click` toggle with
    `phx-click-away` dismiss. Requires a LiveView/LiveComponent context.
    Set `target` to `@myself` when used inside a LiveComponent.

  The trigger button uses a consistent 36px rounded icon-button style.

  ## Examples

      <%!-- CSS mode — works in dead views --%>
      <.header_dropdown aria_label="Wallet">
        <:trigger>
          <.icon name="lucide-coins" class="w-4 h-4" />
        </:trigger>
        <:panel>
          <p>Panel content</p>
        </:panel>
      </.header_dropdown>

      <%!-- Live mode — phx-managed toggle --%>
      <.header_dropdown open={@open?} target={@myself} aria_label="Notifications">
        <:trigger>
          <.icon name="lucide-bell" class="w-4 h-4" />
        </:trigger>
        <:panel>
          <p>Interactive content with phx-click handlers</p>
        </:panel>
      </.header_dropdown>
  """
  attr :open, :boolean,
    default: nil,
    doc: "nil = CSS mode, true/false = live mode with phx-click toggle"

  attr :target, :any, default: nil, doc: "phx-target for live mode events (e.g. @myself)"
  attr :width_class, :string, default: "w-72", doc: "width class for the panel"
  attr :panel_class, :string, default: nil, doc: "additional classes on the panel"
  attr :aria_label, :string, default: nil, doc: "accessible label for the trigger button"
  attr :trigger_class, :string, default: nil, doc: "override classes on the trigger button"

  attr :placement, :string,
    default: "down-end",
    values: ["down-end", "right-end"],
    doc:
      "panel placement relative to trigger. `down-end` opens below, right-aligned. `right-end` opens to the right, bottom-aligned (use for left-side vertical strips)."

  slot :trigger, required: true, doc: "content inside the trigger button"
  slot :panel, required: true, doc: "dropdown panel content"

  def header_dropdown(assigns) do
    daisy_placement =
      case assigns.placement do
        "right-end" -> "dropdown-right dropdown-end"
        _ -> "dropdown-end"
      end

    live_panel_position =
      case assigns.placement do
        "right-end" -> "left-full bottom-0 ml-2"
        _ -> "right-0 mt-2"
      end

    trigger_class =
      assigns.trigger_class ||
        "flex items-center justify-center w-9 h-9 rounded-lg hover:bg-base-300 transition-colors cursor-pointer relative"

    assigns =
      assigns
      |> assign(:daisy_placement, daisy_placement)
      |> assign(:live_panel_position, live_panel_position)
      |> assign(:trigger_class, trigger_class)

    ~H"""
    <div>
      <%= if @open == nil do %>
        <%!-- CSS mode: DaisyUI focus-based dropdown --%>
        <div class={["dropdown", @daisy_placement]}>
          <button tabindex="0" aria-label={@aria_label} class={@trigger_class}>
            {render_slot(@trigger)}
          </button>
          <div
            tabindex="0"
            class={[
              "dropdown-content z-50 bg-wb-surface border border-wb-border-strong rounded-xl shadow-xl",
              if(@placement == "right-end", do: "ml-2", else: "mt-2"),
              @width_class,
              @panel_class
            ]}
          >
            {render_slot(@panel)}
          </div>
        </div>
      <% else %>
        <%!-- Live mode: phx-click managed toggle --%>
        <div
          class="relative"
          phx-click-away="close"
          phx-window-keydown="close"
          phx-key="Escape"
          phx-target={@target}
        >
          <button
            phx-click="toggle"
            phx-target={@target}
            aria-label={@aria_label}
            class={@trigger_class}
          >
            {render_slot(@trigger)}
          </button>
          <div
            :if={@open}
            class={[
              "absolute z-50 bg-wb-surface border border-wb-border-strong rounded-xl shadow-xl",
              @live_panel_position,
              @width_class,
              @panel_class
            ]}
          >
            {render_slot(@panel)}
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a dropdown menu using the HTML Popover API.

  This component solves overflow clipping issues that occur with CSS-based dropdowns
  inside scrollable containers. The popover renders in the top layer, above all other elements.

  ## Examples

      <.popover_menu id="user-menu">
        <:trigger>
          <.icon name="lucide-more-vertical" class="w-4 h-4" />
        </:trigger>
        <:item>
          <button phx-click="edit">Edit</button>
        </:item>
        <:item>
          <button phx-click="delete" class="text-error">Delete</button>
        </:item>
      </.popover_menu>

  ## Positioning

  The component uses CSS anchor positioning where supported, with a JavaScript
  fallback for older browsers. Position the trigger element as needed in your layout.
  """
  attr :id, :string, required: true, doc: "unique identifier for the popover"
  attr :class, :string, default: nil, doc: "additional CSS classes for the menu"
  attr :trigger_class, :string, default: nil, doc: "override classes on the trigger button"
  attr :wrapper_class, :string, default: nil, doc: "override classes on the wrapper element"

  attr :position, :string,
    default: "bottom-end",
    values: ["bottom-start", "bottom-end", "top-start", "top-end"],
    doc: "menu position relative to trigger"

  slot :trigger, required: true, doc: "the element that triggers the popover"

  slot :item, required: true, doc: "menu items to display" do
    attr :class, :string, doc: "additional CSS classes for the menu item"
  end

  def popover_menu(assigns) do
    ~H"""
    <div class={@wrapper_class || "relative inline-block"}>
      <button
        type="button"
        popovertarget={@id}
        class={@trigger_class || "icon-btn"}
        id={"#{@id}-trigger"}
      >
        {render_slot(@trigger)}
      </button>
      <ul
        id={@id}
        popover="auto"
        phx-hook="PopoverPosition"
        data-trigger-id={"#{@id}-trigger"}
        data-position={@position}
        class={[
          "menu menu-sm bg-base-100 border border-base-300 rounded w-28 p-1",
          "shadow-lg",
          "m-0",
          @class
        ]}
      >
        <li :for={item <- @item} class={item[:class]}>
          {render_slot(item)}
        </li>
      </ul>
    </div>
    """
  end
end
