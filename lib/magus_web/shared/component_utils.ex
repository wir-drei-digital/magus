defmodule MagusWeb.Live.Shared.ComponentUtils do
  @moduledoc """
  Shared utilities for LiveComponents.

  Provides common functions that are duplicated across multiple components.

  ## Usage

      defmodule MyComponent do
        use MagusWeb, :live_component
        use MagusWeb.Live.Shared.ComponentUtils

        # Now you can use notify_parent/1 and shared formatting functions
        def handle_event("save", _, socket) do
          notify_parent(:saved)
          {:noreply, socket}
        end
      end
  """

  use Gettext, backend: MagusWeb.Gettext

  defmacro __using__(_opts) do
    quote do
      import MagusWeb.Live.Shared.ComponentUtils,
        only: [format_execution_time: 1, prompt_type_label: 1]

      # Notifies the parent LiveView with a message tagged by this module.
      # The message is sent as `{ModuleName, msg}` so the parent can pattern match
      # on the component that sent the message.
      defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
    end
  end

  @doc """
  Formats execution time in milliseconds to a human-readable string.

  Returns "Xms" for times under 1 second, "X.Xs" for longer durations.

  ## Examples

      iex> format_execution_time(500)
      "500ms"

      iex> format_execution_time(2500)
      "2.5s"

      iex> format_execution_time(nil)
      nil
  """
  @spec format_execution_time(number() | nil) :: String.t() | nil
  def format_execution_time(nil), do: nil
  def format_execution_time(ms) when is_number(ms) and ms < 1000, do: "#{ms}ms"
  def format_execution_time(ms) when is_number(ms), do: "#{Float.round(ms / 1000, 1)}s"
  def format_execution_time(_), do: nil

  @doc """
  Returns a localized label for prompt types.

  ## Examples

      iex> prompt_type_label(:system)
      "System"

      iex> prompt_type_label(:user)
      "User"
  """
  @spec prompt_type_label(atom()) :: String.t()
  def prompt_type_label(:system), do: gettext("System")
  def prompt_type_label(:user), do: gettext("User")
  def prompt_type_label(_), do: gettext("Unknown")
end
