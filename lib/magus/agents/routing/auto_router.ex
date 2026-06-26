defmodule Magus.Agents.Routing.AutoRouter do
  @moduledoc """
  Automatic model routing based on message intent and complexity.

  Analyzes user messages and selects the optimal model from routing-eligible
  models in the database. Only activates when the user has no explicit model
  selection (i.e., neither conversation nor user has a pinned model).

  ## Classification

  Messages are classified along two dimensions:

  - **Intent**: `:chat`, `:coding`, `:search`, `:reasoning`, `:creative`
  - **Complexity**: `:simple`, `:medium`, `:hard`

  ## Model Matching

  Classification is mapped to models via `RoutingSlot` records (specialty + tier).
  The matcher finds the best available model for the detected intent and complexity.
  """

  require Logger

  alias Magus.Agents.Actions.ClassifyIntent
  alias Magus.Agents.Routing.ModelMatcher

  defmodule Classification do
    @moduledoc false
    defstruct [
      :intent,
      :complexity,
      :confidence,
      method: :heuristic
    ]

    @type t :: %__MODULE__{
            intent: :chat | :coding | :search | :reasoning | :creative,
            complexity: :simple | :medium | :hard,
            confidence: float(),
            method: :heuristic | :llm
          }
  end

  @doc """
  Routes a message to the best available model.

  Returns `{:ok, model_key, classification}` if a routing-eligible model was
  found, or `:no_route` if auto-routing should be skipped (falls back to
  system default).

  ## Parameters

  - `text` - The user's message text
  - `opts` - Optional metadata:
    - `:mode` - Current chat mode (e.g., `:search` already set by user)
    - `:metadata` - Message metadata (e.g., pdf_selection, service_selection)
    - `:max_tier` - Maximum routing tier
    - `:user_id` - User ID for usage recording
    - `:conversation_id` - Conversation ID for usage recording
  """
  @spec route(String.t(), keyword()) ::
          {:ok, String.t(), Classification.t()} | :no_route
  def route(text, opts \\ []) do
    max_tier = Keyword.get(opts, :max_tier)

    {:ok, %{classification: classification}} =
      ClassifyIntent.run(
        %{
          text: text,
          mode: Keyword.get(opts, :mode, :chat),
          metadata: Keyword.get(opts, :metadata, %{}),
          user_id: Keyword.get(opts, :user_id),
          conversation_id: Keyword.get(opts, :conversation_id)
        },
        %{}
      )

    Logger.info(
      "AutoRouter: classified message as #{classification.intent}/#{classification.complexity} " <>
        "(confidence=#{classification.confidence}, method=#{classification.method}), " <>
        "text=#{inspect(String.slice(text || "", 0, 80))}"
    )

    required_modalities = Keyword.get(opts, :required_modalities, [])

    case ModelMatcher.find_model(classification,
           max_tier: max_tier,
           required_modalities: required_modalities
         ) do
      {:ok, model_key} ->
        Logger.info("AutoRouter: routed to model_key=#{model_key}")
        {:ok, model_key, classification}

      :no_match ->
        Logger.info("AutoRouter: no matching routing slot found, returning :no_route")
        :no_route
    end
  end
end
