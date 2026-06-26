defmodule Magus.SuperBrain.ExtractionBudget do
  @moduledoc """
  Per-user, per-day extraction budget counter.

  Used by the Super Brain extraction pipeline to enforce a daily ceiling on
  LLM calls and to track cumulative cost. The increment path uses raw SQL
  `INSERT ... ON CONFLICT DO UPDATE` so that concurrent extraction workers
  can update the same row atomically without read-modify-write races.

  This resource is system-internal: it is accessed via the helper functions
  (`atomic_increment/3`, `get_for/2`, `would_exceed_ceiling?/2`) rather than
  via user-actor Ash queries, so no policies are defined.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.SuperBrain,
    data_layer: AshPostgres.DataLayer

  require Ash.Query
  require Logger

  @default_daily_ceiling 5000

  postgres do
    table "super_brain_extraction_budget"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      accept [:user_id, :date, :ceiling_call_count]
      upsert? true
      upsert_identity :unique_user_date
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :user_id, :uuid, allow_nil?: false
    attribute :date, :date, allow_nil?: false
    attribute :llm_call_count, :integer, default: 0
    attribute :llm_cost_cents, :integer, default: 0
    attribute :ceiling_call_count, :integer, default: @default_daily_ceiling
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_user_date, [:user_id, :date], pre_check_with: Magus.SuperBrain
  end

  def atomic_increment(user_id, date, opts) do
    calls = Keyword.get(opts, :calls, 0)
    cost_cents = Keyword.get(opts, :cost_cents, 0)

    Magus.Repo.query!(
      """
      INSERT INTO super_brain_extraction_budget
        (id, user_id, date, llm_call_count, llm_cost_cents, ceiling_call_count, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())
      ON CONFLICT (user_id, date)
      DO UPDATE SET
        llm_call_count = super_brain_extraction_budget.llm_call_count + $4,
        llm_cost_cents = super_brain_extraction_budget.llm_cost_cents + $5,
        updated_at = NOW()
      """,
      [
        Ecto.UUID.dump!(Ash.UUIDv7.generate()),
        Ecto.UUID.dump!(user_id),
        date,
        calls,
        cost_cents,
        @default_daily_ceiling
      ]
    )

    :ok
  end

  def get_for(user_id, date) do
    __MODULE__
    |> Ash.Query.filter(user_id: user_id, date: date)
    |> Ash.read_one()
  end

  @doc """
  Returns true if making one more LLM call would reach or exceed the daily
  ceiling for the given user/date. Used as a killswitch by the extraction
  pipeline before each LLM call.

  Returns true on errors as a safety fallback so a broken read never lets the
  pipeline run unbounded.
  """
  def would_exceed_ceiling?(user_id, date) do
    case get_for(user_id, date) do
      {:ok, %{llm_call_count: count, ceiling_call_count: ceiling}} ->
        count + 1 >= ceiling

      {:ok, nil} ->
        false

      {:error, reason} ->
        Logger.warning(
          "ExtractionBudget read failed for user=#{inspect(user_id)} date=#{date}; failing closed",
          reason: inspect(reason)
        )

        true

      _ ->
        Logger.warning(
          "ExtractionBudget read returned unexpected shape for user=#{inspect(user_id)} date=#{date}; failing closed"
        )

        true
    end
  end
end
