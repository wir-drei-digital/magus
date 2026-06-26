defmodule Magus.SuperBrain.Usage do
  @moduledoc """
  Value type for LLM call token and cost data, plus a helper to persist it
  as a `Magus.Usage.MessageUsage` row.

  Used by `Magus.SuperBrain.LLMClient` (extraction) and `Magus.Embeddings.Embedder`
  (search-time query embedding) to surface unified usage tracking.
  """

  alias Magus.Chat
  alias Magus.Usage.MessageUsage

  defstruct [
    :model_name,
    :provider,
    prompt_tokens: 0,
    completion_tokens: 0,
    total_tokens: 0,
    cached_tokens: 0,
    reasoning_tokens: nil,
    input_cost: Decimal.new("0"),
    output_cost: Decimal.new("0"),
    total_cost: Decimal.new("0")
  ]

  @type t :: %__MODULE__{
          model_name: String.t() | nil,
          provider: String.t() | nil,
          prompt_tokens: integer(),
          completion_tokens: integer(),
          total_tokens: integer(),
          cached_tokens: integer(),
          reasoning_tokens: integer() | nil,
          input_cost: Decimal.t(),
          output_cost: Decimal.t(),
          total_cost: Decimal.t()
        }

  @doc """
  Creates a `Magus.Usage.MessageUsage` row attributed to the given user with
  the given usage_type. `model_id` is resolved by name; if no matching model
  is found in the catalog, `model_id` is left nil.

  Returns `{:ok, row}` on success, `{:error, changeset}` on failure. Extra
  `opts` are forwarded to `Ash.create/3`; callers that run inside a manual
  transaction can pass `return_notifications?: true` to receive the
  notifications as `{:ok, row, notifications}` and dispatch them after commit.
  """
  @spec write_message_usage(t(), String.t(), atom(), keyword()) ::
          {:ok, term()} | {:ok, term(), list()} | {:error, term()}
  def write_message_usage(%__MODULE__{} = usage, user_id, usage_type, opts \\ [])
      when is_binary(user_id) and is_atom(usage_type) do
    model_id = resolve_model_id(usage.model_name)

    attrs =
      %{
        user_id: user_id,
        model_id: model_id,
        model_name: usage.model_name,
        provider: usage.provider,
        usage_type: usage_type,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        total_tokens: usage.total_tokens,
        cached_tokens: usage.cached_tokens,
        reasoning_tokens: usage.reasoning_tokens,
        input_cost: usage.input_cost,
        output_cost: usage.output_cost,
        total_cost: usage.total_cost,
        # Both callers (Super Brain extraction, search-time query embeddings) are
        # background/system operations, not user chat responses, so they must not
        # count against the user's usage limits. A billable path should use
        # `Magus.Agents.Persistence.UsageRecorder` instead.
        billable: false
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Ash.create(MessageUsage, attrs, Keyword.merge([action: :create, authorize?: false], opts))
  end

  defp resolve_model_id(nil), do: nil

  defp resolve_model_id(name) when is_binary(name) do
    case Chat.get_model_by_name(name) do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
