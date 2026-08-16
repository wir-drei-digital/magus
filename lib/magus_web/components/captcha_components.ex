defmodule MagusWeb.CaptchaComponents do
  @moduledoc "Renders the Turnstile widget when captcha is enabled; nothing otherwise."
  use Phoenix.Component

  def captcha(assigns) do
    assigns = assign(assigns, :enabled?, Magus.Captcha.enabled?())

    ~H"""
    <div :if={@enabled?} class="flex justify-center">
      <Turnstile.script />
      <Turnstile.widget theme="auto" />
    </div>
    """
  end
end
