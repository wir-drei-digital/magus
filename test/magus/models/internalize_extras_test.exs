defmodule Magus.Models.InternalizeExtrasTest do
  use Magus.DataCase, async: false

  alias Magus.Models.InternalizeExtras

  # The curated catalog moved to MagusCloud.Models.Catalog (magus-mxj5.6), so the
  # open-core catalog is empty and InternalizeExtras has nothing to internalize:
  # a self-host install gets no internal model rows. The helper (and the
  # migration that calls it) must still run cleanly and idempotently.
  test "run/0 creates no rows against the empty open-core catalog, idempotently" do
    before = Magus.Chat.Model |> Ash.read!(authorize?: false) |> length()

    assert :ok = InternalizeExtras.run()
    assert :ok = InternalizeExtras.run()

    after_count = Magus.Chat.Model |> Ash.read!(authorize?: false) |> length()
    assert after_count == before
  end
end
