defmodule Magus.Chat.Conversation.Actions.SummarizeWindow do
  @moduledoc """
  Summarizes a window of conversation messages into a single concise summary
  via one non-streaming LLM call.

  Used by the conversation-compaction Oban trigger to collapse an older slice of
  a conversation into a compact summary an assistant can continue from.

  ## Input shape

  `summarize/2` accepts a list of message-like structs/maps that expose:

    * `:role` — one of `:system | :user | :agent | :tool` (as on `Magus.Chat.Message`)
    * `:text` — the message body (string)

  This is exactly the shape of the windowed `Magus.Chat.Message` structs the
  compaction worker holds, so they can be passed straight through. Maps with
  string keys (`"role"` / `"text"`) are also accepted for convenience.

  ## Model selection

  Uses `Magus.Agents.Config.summary_model/0` (the `:summary` role, a cheap/fast
  default) by default. Override with the `:model` option.

  ## Return values

    * `{:ok, summary_binary}` on success
    * `{:ok, ""}` when given an empty message list (nothing to summarize)
    * `{:error, reason}` on LLM failure (never raises)

  ## Usage

      {:ok, summary} =
        SummarizeWindow.summarize([
          %{role: :user, text: "Let's plan the launch for Friday."},
          %{role: :agent, text: "Sure, I'll draft the checklist."}
        ])
  """

  require Logger

  alias Magus.Agents.Config
  alias Magus.Agents.Clients.LLM, as: LLMClient

  @system_prompt """
  Summarize the following conversation so an assistant can seamlessly continue it. \
  Preserve key facts, decisions, user preferences, and open threads. \
  Be concise; omit pleasantries.
  """

  @doc """
  Summarize a window of conversation messages into a concise summary.

  See the module doc for the accepted message shape, model selection, and
  return values.

  ## Options

    * `:model` — model key override (defaults to `Magus.Agents.Config.summary_model/0`)
  """
  @spec summarize([map()], keyword()) :: {:ok, binary()} | {:error, term()}
  def summarize(messages, opts \\ [])

  def summarize([], _opts), do: {:ok, ""}

  def summarize(messages, opts) when is_list(messages) do
    model = Keyword.get(opts, :model) || Config.summary_model()
    transcript = build_transcript(messages)

    Logger.debug("SummarizeWindow.summarize",
      model: model,
      message_count: length(messages)
    )

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.system(@system_prompt),
        ReqLLM.Context.user(transcript)
      ])

    case LLMClient.llm_client().generate_text(model, context, []) do
      {:ok, response} ->
        # ReqLLM.Response.text/1 returns nil for a message-less response. Coalesce
        # to "" so a nil summary routes through RunCompaction's {:ok, ""} no-op
        # branch instead of raising CaseClauseError and sticking the row :pending.
        {:ok, ReqLLM.Response.text(response) || ""}

      {:error, error} = err ->
        Logger.error("SummarizeWindow failed", error: inspect(error))
        err
    end
  end

  # Builds a role-prefixed transcript string from the windowed messages.
  defp build_transcript(messages) do
    messages
    |> Enum.map(&format_line/1)
    |> Enum.join("\n")
  end

  defp format_line(message) do
    role = message_role(message)
    text = message_text(message)
    "#{role_label(role)}: #{text}"
  end

  defp message_role(%{role: role}), do: role
  defp message_role(%{"role" => role}), do: role
  defp message_role(_), do: :user

  defp message_text(%{text: text}) when is_binary(text), do: text
  defp message_text(%{"text" => text}) when is_binary(text), do: text
  defp message_text(_), do: ""

  # Map both atom and string roles to a transcript label. String roles are
  # matched explicitly (never String.to_atom/1 on external input).
  defp role_label(role) when role in [:user, "user"], do: "User"
  defp role_label(role) when role in [:agent, "agent", :assistant, "assistant"], do: "Assistant"
  defp role_label(role) when role in [:system, "system"], do: "System"
  defp role_label(role) when role in [:tool, "tool"], do: "Tool"
  defp role_label(role) when is_binary(role), do: String.capitalize(role)
  defp role_label(role), do: role |> to_string() |> String.capitalize()
end
