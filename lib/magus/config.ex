defmodule Magus.Config do
  @moduledoc """
  Centralized configuration access for the Magus application.

  This module provides a single point of access for all application configuration,
  making it easy to trace where configuration values come from and providing
  sensible defaults.

  ## Configuration Sections

  - **Agents** - Agent lifecycle, timeouts, iterations
  - **Memory** - Memory limits, extraction settings
  - **Integrations** - Rate limits per provider/operation
  - **Chat** - Conversation limits, defaults

  ## Usage

      Magus.Config.agent_idle_timeout(:conversation)
      #=> 300_000 (5 minutes)

      Magus.Config.rate_limit(:google_calendar, :list_events)
      #=> {100, :hour}

  ## Override in Config

      # config/config.exs
      config :magus, :agents,
        conversation_idle_timeout: 10 * 60 * 1000
  """

  # =============================================================================
  # Agent Configuration
  # =============================================================================

  @doc """
  Returns the idle timeout for conversation agents.

  After this duration without an attachment (open viewer or in-flight run),
  the agent hibernates to PostgreSQL. Active runs hold an attachment, so an
  agent is never hibernated mid-turn by this timeout.
  """
  @spec agent_idle_timeout(:conversation) :: pos_integer()
  def agent_idle_timeout(:conversation) do
    get(:agents, :conversation_idle_timeout, 5 * 60 * 1000)
  end

  @doc """
  Timeout for synchronous memory context requests.

  BuildMemoryContext is called before each LLM call to load relevant
  memories. If this times out, an empty context is used.
  """
  @spec memory_context_timeout() :: pos_integer()
  def memory_context_timeout do
    get(:agents, :memory_context_timeout, 3_000)
  end

  @doc """
  Maximum number of tool execution iterations in a single response.

  Prevents infinite loops when tools keep calling each other. Individual
  custom agents can override this via `CustomAgent.max_iterations`.
  """
  @spec max_iterations() :: pos_integer()
  def max_iterations do
    get(:agents, :max_iterations, 100)
  end

  @doc """
  Default model for chat responses.

  Resolved via `Magus.Models.Roles`; falls back to the database default
  model when no assignment or config is present (nil on an empty database).
  """
  @spec default_model() :: String.t() | nil
  def default_model do
    Magus.Models.Roles.resolve(:chat_default)
  end

  @doc """
  Model for generating conversation summaries (should be fast/cheap).
  """
  @spec summary_model() :: String.t()
  def summary_model do
    Magus.Models.Roles.resolve(:summary)
  end

  @doc """
  Model for generating conversation titles.
  """
  @spec title_model() :: String.t()
  def title_model do
    Magus.Models.Roles.resolve(:title_generation)
  end

  @doc """
  Model for generating embeddings.
  """
  @spec embedding_model() :: String.t()
  def embedding_model do
    Magus.Models.Roles.resolve(:embeddings)
  end

  @doc """
  Model for memory extraction (should be fast/cheap).
  """
  @spec extraction_model() :: String.t()
  def extraction_model do
    Magus.Models.Roles.resolve(:memory_extraction)
  end

  # =============================================================================
  # Memory Configuration
  # =============================================================================

  @doc """
  Maximum characters allowed in memory content.
  """
  @spec max_content_chars() :: pos_integer()
  def max_content_chars do
    get(Magus.Memory, :max_content_chars, 8_000)
  end

  @doc """
  Maximum characters allowed in memory summary.
  """
  @spec max_summary_chars() :: pos_integer()
  def max_summary_chars do
    get(Magus.Memory, :max_summary_chars, 500)
  end

  @doc """
  Maximum memories per conversation (local scope).
  """
  @spec max_memories_per_conversation() :: pos_integer()
  def max_memories_per_conversation do
    get(Magus.Memory, :max_memories_per_conversation, 20)
  end

  @doc """
  Memory extraction frequency setting.

  - `:every_message` - Extract after every user/agent exchange
  - `{:every_nth, n}` - Extract every nth message
  - `:on_demand` - Only extract when explicitly requested
  """
  @spec extraction_frequency() :: :every_message | {:every_nth, pos_integer()} | :on_demand
  def extraction_frequency do
    get(Magus.Memory, :extraction_frequency, :every_message)
  end

  @doc """
  Message threshold before triggering extraction (when using message-based triggers).
  """
  @spec extraction_message_threshold() :: pos_integer()
  def extraction_message_threshold do
    get(Magus.Memory, :extraction_message_threshold, 5)
  end

  @doc """
  Days after which unused memories are considered stale and may be deactivated.
  """
  @spec stale_memory_threshold_days() :: pos_integer()
  def stale_memory_threshold_days do
    get(Magus.Memory, :stale_threshold_days, 90)
  end

  # =============================================================================
  # Integration Configuration
  # =============================================================================

  @doc """
  Returns the rate limit for a given provider and operation.

  Returns a tuple of `{count, period}` where period is `:minute` or `:hour`.

  ## Examples

      iex> Magus.Config.rate_limit(:google_calendar, :list_events)
      {100, :hour}

      iex> Magus.Config.rate_limit(:telegram, :send_message)
      {30, :minute}
  """
  @spec rate_limit(atom(), atom()) :: {pos_integer(), :minute | :hour}
  def rate_limit(provider, operation) do
    limits = get(:integrations, :rate_limits, default_rate_limits())
    get_in(limits, [provider, operation]) || {100, :hour}
  end

  @doc """
  Returns all rate limits for a provider.
  """
  @spec rate_limits_for_provider(atom()) :: map()
  def rate_limits_for_provider(provider) do
    limits = get(:integrations, :rate_limits, default_rate_limits())
    Map.get(limits, provider, %{})
  end

  defp default_rate_limits do
    %{
      google_calendar: %{
        list_events: {100, :hour},
        create_event: {50, :hour},
        update_event: {50, :hour},
        delete_event: {50, :hour},
        list_calendars: {100, :hour}
      },
      telegram: %{
        send_message: {30, :minute},
        webhook: {100, :minute}
      },
      simple_webhook: %{
        webhook: {200, :minute},
        send_message: {100, :minute}
      }
    }
  end

  # =============================================================================
  # Chat Configuration
  # =============================================================================

  @doc """
  Maximum unfiled conversations to show in sidebar.
  """
  @spec unfiled_conversations_limit() :: pos_integer()
  def unfiled_conversations_limit do
    get(Magus.Chat, :unfiled_conversations_limit, 20)
  end

  # =============================================================================
  # Email Tool Configuration
  # =============================================================================

  @doc """
  Rate limit for email sending (minutes between emails to same recipient).
  """
  @spec email_rate_limit_minutes() :: pos_integer()
  def email_rate_limit_minutes do
    get(Magus.Agents.Tools.Email.SendEmail, :rate_limit_minutes, 15)
  end

  @doc """
  Maximum subject length for emails.
  """
  @spec email_max_subject_length() :: pos_integer()
  def email_max_subject_length do
    get(Magus.Agents.Tools.Email.SendEmail, :max_subject_length, 100)
  end

  @doc """
  Maximum body length for emails.
  """
  @spec email_max_body_length() :: pos_integer()
  def email_max_body_length do
    get(Magus.Agents.Tools.Email.SendEmail, :max_body_length, 10_000)
  end

  # =============================================================================
  # Application Configuration
  # =============================================================================

  @doc """
  The base URL for the application (used in emails, callbacks, etc).
  """
  @spec app_url() :: String.t()
  def app_url do
    Application.get_env(:magus, :app_url, "http://localhost:4000")
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp get(domain, key, default) when is_atom(domain) do
    Application.get_env(:magus, domain, [])
    |> Keyword.get(key, default)
  end
end
