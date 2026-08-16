defmodule MagusWeb.CaptchaComponents do
  @moduledoc """
  Renders the Turnstile widget when captcha is enabled; nothing otherwise.

  `<Turnstile.script />` is NOT rendered here — it lives in the root layout's
  `<head>`, ahead of app.js, so the Cloudflare script (and the global
  `turnstile` it defines) is guaranteed to load before the LiveSocket mounts
  the Turnstile hook. See root.html.heex.
  """
  use Phoenix.Component

  def captcha(assigns) do
    assigns =
      assigns
      |> assign(:enabled?, Magus.Captcha.enabled?())
      |> assign(:site_key, Magus.Captcha.site_key())

    ~H"""
    <div :if={@enabled?} class="flex justify-center">
      <Turnstile.widget theme="auto" sitekey={@site_key} />
    </div>
    """
  end
end
