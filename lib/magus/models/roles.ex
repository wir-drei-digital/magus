defmodule Magus.Models.Roles do
  @moduledoc """
  Code-defined registry of internal model roles: every place the app itself
  (not the user) picks a model. A role exists if and only if a call site
  uses it, so this list is a complete map of the instance's model needs.

  Resolution precedence (see `resolve/1`, added with the RoleAssignment
  resource): DB assignment > legacy `:agents` config > code default > the
  fallback role's resolution.

  Field semantics:
  - `capability` — what kind of model the role needs (drives the future
    admin picker filter): `:chat | :embedding | :image | :video`
  - `config_key` — legacy `config :magus, :agents` key honored for
    back-compat; an explicitly-set nil disables a nilable role
  - `default` — code-default model spec (nil = none)
  - `nilable?` — when true, the role may resolve to nil and its feature
    degrades gracefully (no fallback chain)
  - `fallback` — role to resolve when everything above yields nothing
  """

  require Logger

  @type role :: %{
          key: atom(),
          description: String.t(),
          capability: :chat | :embedding | :image | :video,
          config_key: atom() | nil,
          default: String.t() | nil,
          nilable?: boolean(),
          fallback: atom() | nil
        }

  @roles [
    %{
      key: :chat_default,
      description: "Default chat model when the user has not selected one",
      capability: :chat,
      config_key: :default_model,
      default: nil,
      nilable?: false,
      fallback: nil
    },
    %{
      key: :title_generation,
      description: "Conversation title generation (fast/cheap)",
      capability: :chat,
      config_key: :title_model,
      default: "openrouter:anthropic/claude-haiku-4.5",
      nilable?: false,
      fallback: :summary
    },
    %{
      key: :summary,
      description: "Conversation/context summarization (fast/cheap)",
      capability: :chat,
      config_key: :summary_model,
      default: "openrouter:anthropic/claude-haiku-4.5",
      nilable?: false,
      fallback: :chat_default
    },
    %{
      key: :memory_extraction,
      description: "Extracting memories from conversation turns",
      capability: :chat,
      config_key: :extraction_model,
      default: nil,
      nilable?: false,
      fallback: :summary
    },
    %{
      key: :intent_classification,
      description: "Auto-router intent classification; disabled = heuristics only",
      capability: :chat,
      config_key: :classification_model,
      default: "openrouter:mistralai/ministral-3b-2512",
      nilable?: true,
      fallback: nil
    },
    %{
      key: :embeddings,
      description:
        "pgvector embeddings for memory/brain/library/files search. " <>
          "Changing the model changes vector dimensions and requires re-embedding",
      capability: :embedding,
      config_key: :embedding_model,
      default: "openai/text-embedding-3-small",
      nilable?: false,
      fallback: nil
    },
    %{
      key: :super_brain_extraction,
      description: "Super Brain entity/relationship extraction (structured output)",
      capability: :chat,
      config_key: :super_brain_extraction_model,
      default: "openrouter:google/gemini-3.1-flash-lite-preview",
      nilable?: false,
      fallback: nil
    },
    %{
      key: :image_default,
      description: "Default image generation model",
      capability: :image,
      config_key: nil,
      default: "openrouter:google/gemini-3.1-flash-image-preview",
      nilable?: false,
      fallback: nil
    },
    %{
      key: :video_t2v,
      description: "Text-to-video generation model",
      capability: :video,
      config_key: nil,
      default: "openrouter:google/veo-3.1-fast",
      nilable?: false,
      fallback: nil
    },
    %{
      key: :video_i2v,
      description: "Image-to-video generation model",
      capability: :video,
      config_key: nil,
      default: "openrouter:google/veo-3.1-fast",
      nilable?: false,
      fallback: nil
    },
    %{
      key: :sub_agent_default,
      description: "Fallback model for spawned sub-agents without an explicit model",
      capability: :chat,
      config_key: :default_model,
      default: "openrouter:anthropic/claude-sonnet-4",
      nilable?: false,
      fallback: :chat_default
    }
  ]

  @roles_by_key Map.new(@roles, &{&1.key, &1})

  @spec all() :: [role()]
  def all, do: @roles

  @spec get!(atom()) :: role()
  def get!(key), do: Map.fetch!(@roles_by_key, key)

  @doc """
  Resolves a role to a model spec string (or nil for disabled nilable roles).

  Precedence: DB assignment > legacy `:agents` config (an explicitly-set
  nil disables nilable roles) > code default > fallback role's resolution.
  """
  @spec resolve(atom()) :: String.t() | nil
  def resolve(key) do
    {value, _source} = trace(key, MapSet.new())
    value
  end

  @type source ::
          :assignment
          | :disabled
          | :config
          | :default
          | {:fallback, atom()}
          | :none

  @doc """
  Like `resolve/1` but also reports where the winning value came from, for
  admin "why does this value apply" tooling.

  Returns `{value, source}` where `source` is one of:

  - `:assignment` — a DB role assignment with a model won
  - `:disabled` — the feature is turned off and the value is nil. This covers
    both a disabled assignment on a nilable role AND an explicitly-set nil
    `:agents` config on a nilable role: both disable the feature, so they share
    the admin-facing `:disabled` meaning
  - `:config` — a legacy `:agents` config string won
  - `:default` — the role's code default won
  - `{:fallback, role_key}` — resolution fell through to the immediate
    fallback role `role_key`; the reported value is whatever that role
    resolved to, regardless of the source within it
  - `:none` — nothing resolved (value nil, non-nilable chain exhausted)
  """
  @spec explain(atom()) :: {String.t() | nil, source()}
  def explain(key), do: trace(key, MapSet.new())

  defp trace(key, seen) do
    if MapSet.member?(seen, key) do
      raise "model role fallback cycle detected at #{inspect(key)}"
    end

    role = get!(key)
    seen = MapSet.put(seen, key)

    case assignment(role) do
      {:disabled, true} ->
        if role.nilable?, do: {nil, :disabled}, else: trace_after_assignment(role, seen)

      {:model, model_key} ->
        {model_key, :assignment}

      :none ->
        trace_after_assignment(role, seen)
    end
  end

  defp trace_after_assignment(role, seen) do
    case config_value(role) do
      {:set, nil} when role.nilable? -> {nil, :disabled}
      {:set, value} when is_binary(value) -> {value, :config}
      _ -> trace_default(role, seen)
    end
  end

  defp trace_default(%{default: default} = _role, _seen) when is_binary(default),
    do: {default, :default}

  defp trace_default(role, seen), do: trace_fallback(role, seen)

  defp trace_fallback(%{fallback: nil}, _seen), do: {nil, :none}

  defp trace_fallback(%{fallback: fallback}, seen) do
    {value, _source} = trace(fallback, seen)
    {value, {:fallback, fallback}}
  end

  defp assignment(role) do
    lookup_assignment(role)
  rescue
    # Raised (not returned) when the calling process has no sandbox/pool
    # ownership — e.g. agent processes outliving an async test's owner.
    # Resolution degrades to config/defaults, which is its contract anyway.
    _e in DBConnection.OwnershipError -> :none
  catch
    # Checkout exits (pool shutdown, sandbox owner exited mid-checkout)
    # likewise degrade to "no assignment" instead of crashing the caller.
    :exit, _reason -> :none
  end

  defp lookup_assignment(role) do
    case Magus.Models.get_role_assignment(Atom.to_string(role.key), load: [:model]) do
      {:ok, %{disabled?: true}} ->
        {:disabled, true}

      {:ok, %{model: %{key: model_key}}} when is_binary(model_key) ->
        {:model, model_key}

      # row without a usable model (e.g. model since destroyed) — no assignment
      {:ok, _} ->
        :none

      {:error, error} ->
        # Not-found is the normal "no assignment" path; anything else (pool
        # exhaustion, DB down) must be visible since resolution silently
        # degrades to defaults.
        unless not_found?(error) do
          Logger.warning(
            "Roles.assignment lookup failed for #{role.key}: " <>
              Exception.message(error)
          )
        end

        :none
    end
  end

  defp not_found?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found?(_), do: false

  defp config_value(%{config_key: nil}), do: :unset

  defp config_value(%{config_key: config_key}) do
    agents = Application.get_env(:magus, :agents, [])

    if Keyword.has_key?(agents, config_key) do
      {:set, Keyword.get(agents, config_key)}
    else
      :unset
    end
  end
end
