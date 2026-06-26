defmodule Magus.FeatureUsage do
  @moduledoc """
  Domain for tracking feature usage events.

  Used by the onboarding system to track which features users have
  interacted with, enabling progressive disclosure of action cards
  and completion tracking.
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  require Ash.Query

  typescript_rpc do
    # New-chat landing "Try it out" onboarding cards (classic parity).
    resource Magus.FeatureUsage.FeatureUsageEvent do
      rpc_action :onboarding_cards, :onboarding_cards
    end

    # New-chat landing announcements (list + dismiss).
    resource Magus.FeatureUsage.Announcement do
      rpc_action :unseen_announcements, :unseen_announcements
      rpc_action :dismiss_announcement, :dismiss_announcement
    end
  end

  @onboarding_features %{
    "prompts" => %{
      icon: "lucide-puzzle",
      title: %{
        "en" => "Create a reusable prompt",
        "de" => "Erstelle einen Prompt"
      },
      description: %{
        "en" => "Save instructions you use often",
        "de" => "Speichere deine genutzten Prompts"
      }
    },
    "reminders" => %{
      icon: "lucide-bell",
      title: %{"en" => "Set a reminder", "de" => "Erinnere mich"},
      description: %{
        "en" => "I'll follow up on schedule",
        "de" => "Ich melde mich zur geplanten Zeit"
      }
    },
    "web_search" => %{
      icon: "lucide-globe",
      title: %{"en" => "Search the web", "de" => "Durchsuche das Web"},
      description: %{
        "en" => "Find current information online",
        "de" => "Finde aktuelle Informationen online"
      }
    },
    "draft_mode" => %{
      icon: "lucide-file-text",
      title: %{"en" => "Try draft mode", "de" => "Erstelle einen Entwurf"},
      description: %{
        "en" => "Write and iterate together",
        "de" => "Kollaboratives schreiben und verfeinern"
      }
    },
    "council" => %{
      icon: "lucide-users",
      title: %{"en" => "Ask the council", "de" => "Frage den Rat"},
      description: %{
        "en" => "Get multiple model perspectives",
        "de" => "Erhalte verschiedene Modellmeinungen"
      }
    },
    "sandbox" => %{
      icon: "lucide-box",
      title: %{
        "en" => "Run code",
        "de" => "Code ausführen"
      },
      description: %{
        "en" => "Solve a task with live code execution",
        "de" => "Löse eine Aufgabe mit Code"
      }
    },
    "threads" => %{
      icon: "lucide-corner-down-right",
      title: %{
        "en" => "Start a thread",
        "de" => "Starte einen Thread"
      },
      description: %{
        "en" => "Branch off into a focused side conversation",
        "de" => "Verzweige in eine fokussierte Nebenunterhaltung"
      }
    },
    "brains" => %{
      icon: "lucide-brain",
      title: %{
        "en" => "Create a brain",
        "de" => "Erstelle ein Brain"
      },
      description: %{
        "en" => "Create a dedicated knowledge base",
        "de" => "Erstelle deine eigene Wissens-Datenbank"
      }
    }
  }

  resources do
    resource Magus.FeatureUsage.FeatureUsageEvent do
      define :track_feature, action: :track, args: [:user_id, :feature, :action]
      define :list_user_events, action: :for_user
    end

    resource Magus.FeatureUsage.Announcement do
      define :list_announcements, action: :read
      define :get_announcement, action: :read, get_by: [:id]
    end
  end

  @onboarding_feature_keys ~w(prompts reminders web_search draft_mode council sandbox threads brains)

  @doc "Returns the onboarding feature registry (key => card metadata)."
  def onboarding_features, do: @onboarding_features

  @doc "Returns the list of onboarding feature keys."
  def onboarding_feature_keys, do: @onboarding_feature_keys

  @doc """
  Track a feature usage event for the given user.

  Returns `:ok` on success or `{:error, error}` on failure.
  """
  def track(user_id, feature, action, metadata \\ %{}) do
    case track_feature(user_id, feature, action, %{metadata: metadata}, authorize?: false) do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns whether the user has discovered (used) the given feature.
  """
  def discovered?(user_id, feature) do
    Magus.FeatureUsage.FeatureUsageEvent
    |> Ash.Query.filter(user_id == ^user_id and feature == ^feature)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  @doc "Return active announcements the user hasn't seen yet."
  def unseen_announcements(user_id) do
    seen_keys =
      Magus.FeatureUsage.FeatureUsageEvent
      |> Ash.Query.filter(user_id == ^user_id and feature == "announcement" and action == "seen")
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.metadata["announcement_id"])
      |> Enum.reject(&is_nil/1)

    Magus.FeatureUsage.Announcement
    |> Ash.Query.for_read(:active)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(fn a -> a.key in seen_keys end)
  end

  @doc "Mark an announcement as seen by a user."
  def mark_announcement_seen(user_id, announcement_key) do
    track(user_id, "announcement", "seen", %{"announcement_id" => announcement_key})
  end

  @doc """
  Returns the user's unseen announcements as localized cards (key, icon,
  localized title/description, action_payload) for the new-chat landing.
  """
  def unseen_announcement_cards(user_id, locale) do
    user_id
    |> unseen_announcements()
    |> Enum.map(fn announcement ->
      %{
        "key" => announcement.key,
        "icon" => announcement.icon,
        "title" => localized(announcement.title, locale),
        "description" => localized(announcement.description, locale),
        "action_payload" => announcement.action_payload
      }
    end)
  end

  defp localized(map, locale) when is_map(map), do: map[locale] || map["en"] || ""
  defp localized(value, _locale), do: value || ""

  @doc """
  Returns the list of onboarding features the user has not yet discovered.
  """
  def undiscovered_features(user_id) do
    discovered =
      Magus.FeatureUsage.FeatureUsageEvent
      |> Ash.Query.filter(user_id == ^user_id and feature in ^@onboarding_feature_keys)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.feature)
      |> Enum.uniq()

    @onboarding_feature_keys -- discovered
  end

  @doc """
  Builds the new-chat "Try it out" cards for the user's undiscovered features,
  localized to `locale` ("en"/"de"), plus a `first_time` flag (the user has
  discovered nothing yet). Each card carries the `topic` to deeplink as
  `?skill=onboarding&topic=<topic>`.
  """
  def onboarding_cards(user_id, locale) do
    undiscovered = undiscovered_features(user_id)

    cards =
      Enum.map(undiscovered, fn key ->
        meta = Map.fetch!(@onboarding_features, key)

        %{
          "key" => key,
          "icon" => meta.icon,
          "title" => meta.title[locale] || meta.title["en"] || "",
          "description" => meta.description[locale] || meta.description["en"] || "",
          "topic" => key
        }
      end)

    %{"cards" => cards, "first_time" => length(undiscovered) == length(@onboarding_feature_keys)}
  end
end
