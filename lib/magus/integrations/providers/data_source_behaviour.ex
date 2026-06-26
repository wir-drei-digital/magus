defmodule Magus.Integrations.Providers.DataSourceBehaviour do
  @moduledoc """
  Behaviour for data source providers that ingest external data into IngestionEntry records.

  This is separate from the base `Behaviour` to avoid conflicts with `parse_webhook/2`
  which returns InputMessage-shaped data for conversation routing. Data source providers
  implement both behaviours — the base for metadata/auth, and this one for ingestion.

  ## Callbacks

  - `parse_ingestion_payload/2` — Parse raw webhook/poll payload into normalized entries
  - `classify/1` — Classify a parsed entry into severity and title
  - `poll/2` — (Optional) Poll for new entries (pull-type sources only)
  """

  @doc """
  Parse a raw payload into a list of normalized entry maps.

  Each entry map should contain:
  - `:content` (string, required) — the entry content
  - `:severity` (atom) — :critical, :error, :warning, :info, :debug
  - `:title` (string, optional) — summary title
  - `:metadata` (map) — source-specific structured data
  - `:occurred_at` (DateTime) — when the event happened at source
  - `:external_id` (string, optional) — source's unique ID for dedup
  """
  @callback parse_ingestion_payload(payload :: map(), headers :: [{String.t(), String.t()}]) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Classify a parsed entry to determine severity and optional title.

  Called after `parse_ingestion_payload/2` to refine severity based on content
  analysis (e.g., detecting crash signatures in log messages).
  """
  @callback classify(parsed_entry :: map()) :: %{severity: atom(), title: String.t() | nil}

  @doc """
  Poll the external source for new entries. Only required for pull-type providers.

  Credential decryption is handled by the caller (PollDataSource worker) using
  the same pipeline as execute/3.
  """
  @callback poll(
              integration :: Magus.Integrations.UserIntegration.t(),
              credential :: Magus.Integrations.Credential.t() | nil
            ) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Decide whether newly ingested entries should create an AgentInboxEvent.

  Called by ThresholdChecker after entries are stored. Providers implement
  their own threshold logic (e.g., error count in time window, any new items).
  """
  @callback should_create_inbox_event?(
              integration :: Magus.Integrations.UserIntegration.t(),
              new_entries :: [map()]
            ) :: boolean()

  @doc """
  Build the attributes map for the AgentInboxEvent.

  Only called when `should_create_inbox_event?/2` returns `true`.
  Must return a map with keys: `:agent_id`, `:event_type`, `:urgency`,
  `:title`, `:summary`, `:source_type`, `:source_id`, `:payload`, `:idempotency_key`.
  """
  @callback build_inbox_event_attrs(
              integration :: Magus.Integrations.UserIntegration.t(),
              new_entries :: [map()]
            ) :: map()

  @optional_callbacks [poll: 2, should_create_inbox_event?: 2, build_inbox_event_attrs: 2]
end
