defmodule MagusWeb.ChatLive.UI.EventComponent do
  @moduledoc """
  Component for rendering system events in the message stream.

  Events include user join/leave/kick notifications, role changes,
  and conversation renames.
  """
  use MagusWeb, :html

  attr :event, :map, required: true

  def conversation_event(assigns) do
    ~H"""
    <div class="flex justify-center my-3">
      <div class="flex items-center gap-2 text-xs text-base-content/60 bg-base-200 px-4 py-2 rounded-full">
        <.event_icon event_type={@event.event_type} />
        <span>{event_message(@event)}</span>
      </div>
    </div>
    """
  end

  defp event_icon(assigns) do
    ~H"""
    <.icon
      name={icon_for_event(@event_type)}
      class="w-3.5 h-3.5"
    />
    """
  end

  defp icon_for_event(:user_joined), do: "lucide-user-plus"
  defp icon_for_event(:user_left), do: "lucide-log-out"
  defp icon_for_event(:user_kicked), do: "lucide-user-minus"
  defp icon_for_event(:user_muted), do: "lucide-volume-x"
  defp icon_for_event(:user_unmuted), do: "lucide-volume-2"
  defp icon_for_event(:role_changed), do: "lucide-shield-check"
  defp icon_for_event(:conversation_renamed), do: "lucide-pencil"
  defp icon_for_event(_), do: "lucide-info"

  defp event_message(%{event_type: :user_joined, target_user: target_user}) do
    "#{user_name(target_user)} joined the conversation"
  end

  defp event_message(%{event_type: :user_left, target_user: target_user}) do
    "#{user_name(target_user)} left the conversation"
  end

  defp event_message(%{event_type: :user_kicked, user: actor, target_user: target_user}) do
    "#{user_name(target_user)} was removed by #{user_name(actor)}"
  end

  defp event_message(%{event_type: :user_muted, user: actor, target_user: target_user}) do
    "#{user_name(target_user)} was muted by #{user_name(actor)}"
  end

  defp event_message(%{event_type: :user_unmuted, user: actor, target_user: target_user}) do
    "#{user_name(target_user)} was unmuted by #{user_name(actor)}"
  end

  defp event_message(%{
         event_type: :role_changed,
         user: actor,
         target_user: target_user,
         metadata: metadata
       }) do
    new_role = metadata["new_role"] || metadata[:new_role] || "member"
    "#{user_name(actor)} changed #{user_name(target_user)}'s role to #{new_role}"
  end

  defp event_message(%{event_type: :conversation_renamed, user: actor, metadata: metadata}) do
    new_title = metadata["new_title"] || metadata[:new_title] || "Untitled"
    "#{user_name(actor)} renamed the conversation to \"#{new_title}\""
  end

  defp event_message(%{event_type: event_type}) do
    "#{event_type}"
  end

  defp user_name(nil), do: "Someone"
  defp user_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp user_name(%{email: email}) when not is_nil(email), do: to_string(email)
  defp user_name(_), do: "Someone"
end
