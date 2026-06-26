defmodule MagusWeb.Workbench.ModesTest do
  use ExUnit.Case, async: true

  alias MagusWeb.Workbench.Modes

  test "all/0 returns the modes in order" do
    assert [:chat, :brain, :agents, :prompts, :files] = Enum.map(Modes.all(), & &1.key)
  end

  test "get/1 returns the mode by key" do
    assert %{key: :chat, label: "Chats", icon: icon} = Modes.get(:chat)
    assert is_binary(icon) and String.starts_with?(icon, "lucide-")
  end

  test "get/1 returns nil for unknown keys" do
    assert Modes.get(:bogus) == nil
  end

  test "keys/0 returns the atom keys" do
    assert [:chat, :brain, :agents, :prompts, :files] = Modes.keys()
  end

  test "exposes the files mode" do
    assert %{key: :files, label: "Files", icon: icon} = MagusWeb.Workbench.Modes.get(:files)
    assert is_binary(icon) and String.starts_with?(icon, "lucide-")
    assert :files in MagusWeb.Workbench.Modes.keys()
  end
end
