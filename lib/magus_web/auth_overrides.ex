defmodule MagusWeb.AuthOverrides do
  use AshAuthentication.Phoenix.Overrides

  # For a complete reference, see https://hexdocs.pm/ash_authentication_phoenix/ui-overrides.html

  override AshAuthentication.Phoenix.SignInLive do
    set :root_class, "bg-spectral min-h-screen flex items-center justify-center"
  end

  override AshAuthentication.Phoenix.Components.Banner do
    set :image_url, "/images/logo-triangle.svg"
    set :dark_image_url, nil
    set :image_class, "w-12 h-12"
    set :text, "MAGUS"
    set :text_class, "text-3xl font-logo text-base-content"
    set :href_url, "/"
    set :href_class, "flex flex-col items-center gap-2"
    set :root_class, "flex justify-center items-center mb-6 flex-col"
  end

  override AshAuthentication.Phoenix.Components.Password.Input do
    set :remember_me_class, "flex items-center gap-2 mt-3 mb-1 text-sm"
    set :remember_me_input_label, "Remember me for 30 days"
    set :checkbox_class, "checkbox checkbox-sm checkbox-primary"
    set :checkbox_label_class, "label-text cursor-pointer"
    # Validate on blur, not while typing. Otherwise the upstream
    # Reset.Form's update/2 rebuilds the form on each phx-change and the
    # input loses focus mid-keystroke (issue #21).
    set :input_debounce, "blur"
  end
end
