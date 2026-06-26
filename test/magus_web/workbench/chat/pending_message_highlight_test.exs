defmodule MagusWeb.Workbench.Chat.PendingMessageHighlightTest do
  use ExUnit.Case, async: true
  alias MagusWeb.Workbench.Chat.PendingMessageHighlight

  setup do
    PendingMessageHighlight.init()
    :ok
  end

  test "put then take returns the message id once" do
    conv = Ecto.UUID.generate()
    PendingMessageHighlight.put(conv, "msg-9")
    assert PendingMessageHighlight.take(conv) == "msg-9"
    assert PendingMessageHighlight.take(conv) == nil
  end

  test "take/1 returns nil when nothing is stored" do
    assert PendingMessageHighlight.take(Ecto.UUID.generate()) == nil
  end

  test "highlights are scoped per conversation id" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    PendingMessageHighlight.put(a, "msg-for-a")

    # put on conversation A must not affect take on conversation B
    assert PendingMessageHighlight.take(b) == nil
    assert PendingMessageHighlight.take(a) == "msg-for-a"
  end

  test "init/0 is idempotent and does not wipe an existing entry" do
    conv = Ecto.UUID.generate()
    PendingMessageHighlight.put(conv, "msg-keep")

    assert :ok = PendingMessageHighlight.init()

    assert PendingMessageHighlight.take(conv) == "msg-keep"
  end
end
