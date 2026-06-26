defmodule Magus.Usage.CreditStatusTest do
  @moduledoc """
  `Magus.Usage.CreditStatus` is the daily credit/storage snapshot behind the
  shell indicator. It is pure usage-governance (computed from
  `Magus.Usage.Calculator`, no commercial-billing dependency), so it lives in
  `Magus.Usage` rather than `Magus.Billing` (open-core split).
  """
  use Magus.ResourceCase, async: true

  import Magus.Generators

  alias Magus.Usage.CreditStatus

  test "returns nil for a nil actor" do
    assert CreditStatus.compute(nil) == nil
  end

  test "returns nil for an AI-agent actor (credits are a human-shell concern)" do
    assert CreditStatus.compute(%Magus.Agents.Support.AiAgent{user_id: Ecto.UUID.generate()}) ==
             nil
  end

  test "returns a credit/storage snapshot for a user with the daily-credits indicator hidden" do
    user = generate(user())

    snapshot = CreditStatus.compute(user)

    # Daily-credit metering was replaced by pay-as-you-go: credits_limit is nil
    # so the shell indicator stays hidden; storage + exempt remain meaningful.
    assert snapshot.credits_limit == nil
    assert snapshot.credits_used == 0
    assert snapshot.percentage == 0
    assert is_boolean(snapshot.exempt)
    assert is_integer(snapshot.storage_used)
    assert Map.has_key?(snapshot, :storage_limit)
  end
end
