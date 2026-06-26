defmodule Magus.Usage.MeteringSink do
  @moduledoc """
  Receives a recorded billable overage so the billing edition can meter it.
  Core default is a no-op (an unconfigured OSS instance does no metering). The
  combined hosted app configures this to `Magus.Billing.MeteringSink`, which
  enqueues a Stripe meter event.
  """
  defmodule Charge do
    @moduledoc "Neutral description of a billable overage."
    @enforce_keys [:user_id, :overflow_cents, :identifier]
    defstruct [
      :user_id,
      :overflow_cents,
      :identifier,
      :stripe_customer_id,
      :stripe_subscription_id
    ]

    @type t :: %__MODULE__{
            user_id: binary(),
            overflow_cents: non_neg_integer(),
            identifier: binary(),
            stripe_customer_id: binary() | nil,
            stripe_subscription_id: binary() | nil
          }
  end

  @callback report_charge(Charge.t()) :: :ok

  @spec report_charge(Charge.t()) :: :ok
  def report_charge(%Charge{} = charge), do: impl().report_charge(charge)

  @doc """
  Whether commercial metering is wired (a non-`Noop` sink). False on an OSS
  instance with no billing configured; true in the combined/cloud app. Core
  code uses this to gate billing-only UI (e.g. price fields in the plans admin)
  without naming the billing edition.
  """
  @spec configured?() :: boolean()
  def configured?, do: impl() != __MODULE__.Noop

  defp impl,
    do: Application.get_env(:magus, __MODULE__, [])[:impl] || __MODULE__.Noop

  defmodule Noop do
    @moduledoc false
    @behaviour Magus.Usage.MeteringSink
    @impl true
    def report_charge(_charge), do: :ok
  end
end
