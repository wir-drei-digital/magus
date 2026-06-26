defmodule MagusWeb.Workbench.Modes do
  @moduledoc """
  Single source of truth for workbench modes. Consumed by ModeStrip (for the
  icon list) and NavPane (for mode dispatch).
  """

  @modes [
    %{key: :chat, icon: "lucide-messages-square", label: "Chats"},
    %{key: :brain, icon: "lucide-brain", label: "Brains"},
    %{key: :agents, icon: "lucide-bot", label: "Agents"},
    %{key: :prompts, icon: "lucide-scroll-text", label: "Prompts"},
    %{key: :files, icon: "lucide-files", label: "Files"}
  ]

  @type key :: :chat | :brain | :agents | :prompts | :files
  @type t :: %{key: key(), icon: String.t(), label: String.t()}

  @spec all() :: [t()]
  def all, do: @modes

  @spec keys() :: [key()]
  def keys, do: Enum.map(@modes, & &1.key)

  @spec get(key()) :: t() | nil
  def get(key), do: Enum.find(@modes, &(&1.key == key))
end
