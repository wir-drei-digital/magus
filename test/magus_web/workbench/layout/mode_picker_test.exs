defmodule MagusWeb.Workbench.Layout.ModePickerTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias MagusWeb.Workbench.Layout.ModePicker

  test "vertical layout renders a button for every mode in Modes.all/0" do
    html =
      render_component(&ModePicker.mode_picker/1, %{
        current_mode: :chat,
        layout: :vertical
      })

    assert html =~ ~s(data-mode-picker-layout="vertical")

    for mode <- MagusWeb.Workbench.Modes.all() do
      assert html =~ ~s(data-mode-icon="#{mode.key}"),
             ~s(expected button for mode #{mode.key})
    end
  end

  test "horizontal layout exposes layout marker" do
    html =
      render_component(&ModePicker.mode_picker/1, %{
        current_mode: :chat,
        layout: :horizontal
      })

    assert html =~ ~s(data-mode-picker-layout="horizontal")
    assert html =~ ~s(data-mode-icon="chat")
  end

  test "active mode gets the active styling marker" do
    html =
      render_component(&ModePicker.mode_picker/1, %{
        current_mode: :brain,
        layout: :vertical
      })

    # Active mode marked with data-active="true"; inactive with data-active="false"
    assert html =~ ~r/data-mode-icon="brain"[^>]*data-active="true"/
    assert html =~ ~r/data-mode-icon="chat"[^>]*data-active="false"/
  end
end
