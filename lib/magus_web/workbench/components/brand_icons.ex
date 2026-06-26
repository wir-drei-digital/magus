defmodule MagusWeb.BrandIcons do
  @moduledoc """
  Shared brand icon SVG components for third-party service integrations.

  Usage:

      <MagusWeb.BrandIcons.provider_icon provider={:telegram} class="size-10" />

  Or import in a module:

      import MagusWeb.BrandIcons
      <.provider_icon provider={:telegram} class="size-10" />
  """

  use Phoenix.Component

  import MagusWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders a brand icon for a provider inside a colored rounded container.

  ## Attributes

    * `:provider` - Provider atom key (required)
    * `:class` - Container CSS classes. Defaults to `"size-10"`.
  """
  attr :provider, :atom, required: true
  attr :class, :string, default: "size-10"

  def provider_icon(%{provider: :telegram} = assigns) do
    ~H"""
    <div class={["rounded-lg flex items-center justify-center bg-[#26A5E4]", @class]}>
      <.telegram_svg class="size-6" />
    </div>
    """
  end

  def provider_icon(%{provider: :google_calendar} = assigns) do
    ~H"""
    <div class={[
      "rounded-lg flex items-center justify-center bg-white border border-base-300",
      @class
    ]}>
      <.google_calendar_svg class="size-6" />
    </div>
    """
  end

  def provider_icon(%{provider: :notion} = assigns) do
    ~H"""
    <div class={["rounded-lg flex items-center justify-center bg-neutral", @class]}>
      <.notion_svg class="size-6" />
    </div>
    """
  end

  def provider_icon(%{provider: :google_drive} = assigns) do
    ~H"""
    <div class={[
      "rounded-lg flex items-center justify-center bg-white border border-base-300",
      @class
    ]}>
      <.google_drive_svg class="size-6" />
    </div>
    """
  end

  def provider_icon(%{provider: :nextcloud} = assigns) do
    ~H"""
    <div class={["rounded-lg flex items-center justify-center bg-sky-500", @class]}>
      <.icon name="lucide-cloud" class="size-5 text-white" />
    </div>
    """
  end

  def provider_icon(%{provider: :affine} = assigns) do
    ~H"""
    <div class={["rounded-lg flex items-center justify-center bg-violet-500", @class]}>
      <.icon name="lucide-pen-tool" class="size-5 text-white" />
    </div>
    """
  end

  def provider_icon(%{provider: :web} = assigns) do
    ~H"""
    <div class={["rounded-lg flex items-center justify-center bg-indigo-600", @class]}>
      <.icon name="lucide-globe" class="size-5 text-white" />
    </div>
    """
  end

  def provider_icon(%{provider: :api} = assigns) do
    ~H"""
    <div class={["rounded-lg flex items-center justify-center bg-emerald-600", @class]}>
      <.icon name="lucide-code" class="size-5 text-white" />
    </div>
    """
  end

  def provider_icon(assigns) do
    ~H"""
    <div class={["rounded-lg flex items-center justify-center bg-base-content/10", @class]}>
      <.icon name="lucide-plug" class="size-5 text-base-content/60" />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Raw SVGs (no container, just the SVG element)
  # ---------------------------------------------------------------------------

  attr :class, :string, default: "size-5"

  def telegram_svg(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="white" xmlns="http://www.w3.org/2000/svg">
      <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.479.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
    </svg>
    """
  end

  attr :class, :string, default: "size-5"

  def google_calendar_svg(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="#4285F4" xmlns="http://www.w3.org/2000/svg">
      <path d="M18.316 5.684H24v12.632h-5.684V5.684zM5.684 24h12.632v-5.684H5.684V24zM18.316 5.684V0H1.895A1.894 1.894 0 0 0 0 1.895v16.421h5.684V5.684h12.632zm-7.207 6.25v-.065c.272-.144.5-.349.687-.617s.279-.595.279-.982c0-.379-.099-.72-.3-1.025a2.05 2.05 0 0 0-.832-.714 2.703 2.703 0 0 0-1.197-.257c-.6 0-1.094.156-1.481.467-.386.311-.65.671-.793 1.078l1.085.452c.086-.249.224-.461.413-.633.189-.172.445-.257.767-.257.33 0 .602.088.816.264a.86.86 0 0 1 .322.703c0 .33-.12.589-.36.778-.24.19-.535.284-.886.284h-.567v1.085h.633c.407 0 .748.109 1.02.327.272.218.407.499.407.843 0 .336-.129.614-.387.832s-.565.327-.924.327c-.351 0-.651-.103-.897-.311-.248-.208-.422-.502-.521-.881l-1.096.452c.178.616.505 1.082.977 1.401.472.319.984.478 1.538.477a2.84 2.84 0 0 0 1.293-.291c.382-.193.684-.458.902-.794.218-.336.327-.72.327-1.149 0-.429-.115-.797-.344-1.105a2.067 2.067 0 0 0-.881-.689zm2.093-1.931l.602.913L15 10.045v5.744h1.187V8.446h-.827l-2.158 1.557zM22.105 0h-3.289v5.184H24V1.895A1.894 1.894 0 0 0 22.105 0zm-3.289 23.5l4.684-4.684h-4.684V23.5zM0 22.105C0 23.152.848 24 1.895 24h3.289v-5.184H0v3.289z" />
    </svg>
    """
  end

  attr :class, :string, default: "size-5"

  def notion_svg(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path
        d="M6.017 4.313l55.333-4.087c6.797-.583 8.543-.19 12.817 2.917l17.663 12.443c2.913 2.14 3.883 2.723 3.883 5.053v68.243c0 4.277-1.553 6.807-6.99 7.193L24.467 99.967c-4.08.193-6.023-.39-8.16-3.113L3.3 79.94c-2.333-3.113-3.3-5.443-3.3-8.167V11.113c0-3.497 1.553-6.413 6.017-6.8z"
        fill="#fff"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M61.35.227l-55.333 4.087C1.553 4.7 0 7.617 0 11.113v60.66c0 2.723.967 5.053 3.3 8.167l12.993 16.913c2.137 2.723 4.08 3.307 8.16 3.113l64.257-3.89c5.433-.387 6.99-2.917 6.99-7.193V20.64c0-2.21-.873-2.847-3.443-4.733L75.34 3.57c-4.273-3.107-6.02-3.5-12.99-2.91zM25.92 19.523c-5.247.353-6.437.433-9.417-1.99L8.927 11.507c-.77-.78-.383-1.753 1.557-1.947l53.193-3.887c4.467-.39 6.793 1.167 8.54 2.527l9.123 6.61c.39.194 1.36 1.358.193 1.358l-54.93 3.16-.683.196zM19.803 88.3V30.367c0-2.53.778-3.697 3.103-3.893L86 22.78c2.14-.193 3.107 1.167 3.107 3.693v57.547c0 2.53-1.36 4.86-4.667 5.053l-60.15 3.5c-3.303.193-4.487-1.357-4.487-4.277zm56.25-54.427c.39 1.75 0 3.5-1.75 3.7l-2.917.58v42.77c-2.527 1.36-4.853 2.137-6.797 2.137-3.11 0-3.883-.973-6.21-3.887l-19.03-29.94v28.967l6.077 1.36s0 3.5-4.853 3.5l-13.39.78c-.39-.78 0-2.723 1.357-3.11l3.497-.97v-38.3L26.833 41.6c-.39-1.75.583-4.277 3.3-4.473l14.367-.967 19.8 30.327v-26.83l-5.047-.583c-.39-2.143 1.163-3.7 3.103-3.89l13.8-.78z"
        fill="#000"
      />
    </svg>
    """
  end

  attr :class, :string, default: "size-5"

  def google_drive_svg(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 87.3 78" xmlns="http://www.w3.org/2000/svg">
      <path
        d="m6.6 66.85 3.85 6.65c.8 1.4 1.95 2.5 3.3 3.3l13.75-23.8h-27.5c0 1.55.4 3.1 1.2 4.5z"
        fill="#0066da"
      />
      <path
        d="m43.65 25-13.75-23.8c-1.35.8-2.5 1.9-3.3 3.3l-20.4 35.3c-.8 1.4-1.2 2.95-1.2 4.5h27.5z"
        fill="#00ac47"
      />
      <path
        d="m73.55 76.8c1.35-.8 2.5-1.9 3.3-3.3l1.6-2.75 7.65-13.25c.8-1.4 1.2-2.95 1.2-4.5h-27.5l5.85 13.95z"
        fill="#ea4335"
      />
      <path
        d="m43.65 25 13.75-23.8c-1.35-.8-2.9-1.2-4.5-1.2h-18.5c-1.6 0-3.15.45-4.5 1.2z"
        fill="#00832d"
      />
      <path
        d="m59.8 53h-32.3l-13.75 23.8c1.35.8 2.9 1.2 4.5 1.2h50.8c1.6 0 3.15-.45 4.5-1.2z"
        fill="#2684fc"
      />
      <path
        d="m73.4 26.5-10.1-17.5c-.8-1.4-1.95-2.5-3.3-3.3l-13.75 23.8 16.15 23.8h27.45c0-1.55-.4-3.1-1.2-4.5z"
        fill="#ffba00"
      />
    </svg>
    """
  end
end
