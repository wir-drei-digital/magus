defmodule Magus.Agents.CustomAgentAttachment.Validations.WithinLimits do
  @moduledoc """
  Ensures the parent agent stays under AttachmentLimits when creating or
  changing the mode of an attachment.

  Validates:
  - count: total attachments per agent
  - always-tokens: sum of chunk token_count across :always-mode attachments
  - total-size: sum of file_size across all attachments
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias Magus.Agents.AttachmentLimits

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _ctx) do
    agent_id = Ash.Changeset.get_attribute(changeset, :custom_agent_id)
    new_mode = Ash.Changeset.get_attribute(changeset, :mode)
    new_file_id = Ash.Changeset.get_attribute(changeset, :file_id)
    is_create? = changeset.action_type == :create

    case agent_id do
      nil ->
        :ok

      _ ->
        existing =
          Magus.Agents.CustomAgentAttachment
          |> Ash.Query.filter(custom_agent_id == ^agent_id)
          |> Ash.Query.load(file: [:chunks])
          |> Ash.read!(authorize?: false)

        # Effective set after this change
        effective =
          if is_create? do
            existing ++ [%{mode: new_mode, file_id: new_file_id, file: nil}]
          else
            id = changeset.data.id

            Enum.map(existing, fn att ->
              if att.id == id,
                do: %{
                  id: att.id,
                  mode: new_mode || att.mode,
                  file_id: att.file_id,
                  file: att.file
                },
                else: att
            end)
          end

        cond do
          AttachmentLimits.exceeds_attachment_count?(length(effective)) ->
            {:error,
             field: :custom_agent_id,
             message:
               "exceeds max attachments per agent (#{AttachmentLimits.max_attachments_per_agent()})"}

          AttachmentLimits.exceeds_always_include_tokens?(sum_always_tokens(effective)) ->
            {:error,
             field: :mode,
             message:
               "exceeds max always-include tokens (#{AttachmentLimits.max_always_include_tokens()})"}

          AttachmentLimits.exceeds_total_size?(sum_size(effective)) ->
            {:error,
             field: :file_id,
             message:
               "exceeds max total attachment size (#{AttachmentLimits.max_total_size_bytes()} bytes)"}

          true ->
            :ok
        end
    end
  end

  defp sum_always_tokens(attachments) do
    attachments
    |> Enum.filter(&(Map.get(&1, :mode) == :always))
    |> Enum.map(fn att ->
      file = Map.get(att, :file)

      case file do
        %{chunks: chunks} when is_list(chunks) ->
          Enum.reduce(chunks, 0, fn c, acc -> acc + (c.token_count || 0) end)

        _ ->
          0
      end
    end)
    |> Enum.sum()
  end

  defp sum_size(attachments) do
    Enum.reduce(attachments, 0, fn att, acc ->
      case Map.get(att, :file) do
        %{file_size: s} when is_integer(s) -> acc + s
        _ -> acc
      end
    end)
  end
end
