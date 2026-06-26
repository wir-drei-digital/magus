defmodule Magus.Integrations.IngestionEntry do
  @moduledoc """
  Normalized storage for ingested data from external sources (logs, RSS, email).

  Each entry represents one item from a data source integration. Entries are
  deduplicated per integration via content_hash and auto-purged based on
  retention configuration.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ingestion_entries"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :source_type,
        :external_id,
        :severity,
        :title,
        :content,
        :metadata,
        :occurred_at,
        :content_hash,
        :user_integration_id,
        :user_id
      ]
    end

    read :for_integration do
      argument :user_integration_id, :uuid, allow_nil?: false
      argument :since, :utc_datetime_usec
      argument :until, :utc_datetime_usec

      argument :severity, :atom,
        constraints: [one_of: [:critical, :error, :warning, :info, :debug]]

      argument :query, :string
      argument :limit, :integer, default: 50

      filter expr(user_integration_id == ^arg(:user_integration_id))

      prepare fn query, _context ->
        require Ash.Query

        query
        |> then(fn q ->
          if q.arguments[:since],
            do: Ash.Query.filter(q, occurred_at >= ^q.arguments.since),
            else: q
        end)
        |> then(fn q ->
          if q.arguments[:until],
            do: Ash.Query.filter(q, occurred_at <= ^q.arguments.until),
            else: q
        end)
        |> then(fn q ->
          if q.arguments[:severity],
            do: Ash.Query.filter(q, severity == ^q.arguments.severity),
            else: q
        end)
        |> then(fn q ->
          if q.arguments[:query] do
            Ash.Query.filter(
              q,
              contains(content, ^q.arguments.query) or contains(title, ^q.arguments.query)
            )
          else
            q
          end
        end)
        |> Ash.Query.sort(occurred_at: :desc)
        |> Ash.Query.limit(query.arguments[:limit] || 50)
      end
    end

    read :count_by_severity do
      argument :user_integration_id, :uuid, allow_nil?: false

      argument :severity, :atom,
        allow_nil?: false,
        constraints: [one_of: [:critical, :error, :warning, :info, :debug]]

      argument :since, :utc_datetime_usec, allow_nil?: false

      filter expr(
               user_integration_id == ^arg(:user_integration_id) and
                 severity == ^arg(:severity) and
                 occurred_at >= ^arg(:since)
             )
    end

    read :for_user_sources do
      argument :user_id, :uuid, allow_nil?: false
      argument :source_type, :atom, constraints: [one_of: [:log, :rss, :email]]
      argument :since, :utc_datetime_usec
      argument :until, :utc_datetime_usec
      argument :query, :string

      argument :severity, :atom,
        constraints: [one_of: [:critical, :error, :warning, :info, :debug]]

      argument :limit, :integer, default: 20

      filter expr(user_id == ^arg(:user_id))

      prepare fn query, _context ->
        require Ash.Query

        query
        |> then(fn q ->
          if q.arguments[:source_type],
            do: Ash.Query.filter(q, source_type == ^q.arguments.source_type),
            else: q
        end)
        |> then(fn q ->
          if q.arguments[:since],
            do: Ash.Query.filter(q, occurred_at >= ^q.arguments.since),
            else: q
        end)
        |> then(fn q ->
          if q.arguments[:until],
            do: Ash.Query.filter(q, occurred_at <= ^q.arguments.until),
            else: q
        end)
        |> then(fn q ->
          if q.arguments[:severity],
            do: Ash.Query.filter(q, severity == ^q.arguments.severity),
            else: q
        end)
        |> then(fn q ->
          if q.arguments[:query] do
            Ash.Query.filter(
              q,
              contains(content, ^q.arguments.query) or contains(title, ^q.arguments.query)
            )
          else
            q
          end
        end)
        |> Ash.Query.sort(occurred_at: :desc)
        |> Ash.Query.limit(query.arguments[:limit] || 20)
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type([:create, :destroy]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :source_type, :atom do
      constraints one_of: [:log, :rss, :email]
      allow_nil? false
    end

    attribute :external_id, :string

    attribute :severity, :atom do
      constraints one_of: [:critical, :error, :warning, :info, :debug]
      allow_nil? false
      default :info
    end

    attribute :title, :string
    attribute :content, :string, allow_nil?: false

    attribute :metadata, :map do
      default %{}
    end

    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false

    attribute :content_hash, :string do
      allow_nil? false
      description "SHA-256 of normalized content for dedup"
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user_integration, Magus.Integrations.UserIntegration do
      allow_nil? false
    end

    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end
  end

  identities do
    identity :unique_content_per_integration, [:user_integration_id, :content_hash]
  end
end
