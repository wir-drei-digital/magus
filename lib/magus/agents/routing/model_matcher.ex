defmodule Magus.Agents.Routing.ModelMatcher do
  @moduledoc """
  Matches a classification to the best available routing-eligible model.

  Queries the `RoutingSlot` table for slots with preloaded models, then selects
  based on `specialty` and `tier`.

  ## Matching strategy

  1. Try exact match: specialty + tier for the classification
  2. Try specialty match with any tier
  3. Try tier match with any specialty
  4. Fall back to any routing slot
  5. Return `:no_match` if nothing is eligible

  When multiple slots match the same criteria, the first by specialty + tier
  sort order (from the `list_all` action) is selected.
  """

  require Logger

  alias Magus.Agents.Routing.AutoRouter.Classification

  # Maps {intent, complexity} to desired {specialty, tier}.
  # Specialty and tier are atoms matching the RoutingSlot resource constraints.
  @routing_rules %{
    # Search always routes to search specialist
    {:search, :simple} => %{specialty: :search, tier: :standard},
    {:search, :medium} => %{specialty: :search, tier: :standard},
    {:search, :hard} => %{specialty: :search, tier: :complex},

    # Coding routes by complexity
    {:coding, :simple} => %{specialty: :coding, tier: :simple},
    {:coding, :medium} => %{specialty: :coding, tier: :standard},
    {:coding, :hard} => %{specialty: :coding, tier: :complex},

    # Reasoning always wants complex
    {:reasoning, :simple} => %{specialty: :reasoning, tier: :standard},
    {:reasoning, :medium} => %{specialty: :reasoning, tier: :complex},
    {:reasoning, :hard} => %{specialty: :reasoning, tier: :complex},

    # Creative routes by complexity
    {:creative, :simple} => %{specialty: :creative, tier: :simple},
    {:creative, :medium} => %{specialty: :creative, tier: :standard},
    {:creative, :hard} => %{specialty: :creative, tier: :complex},

    # Chat routes by complexity — the main cost-saving path
    {:chat, :simple} => %{specialty: :general, tier: :simple},
    {:chat, :medium} => %{specialty: :general, tier: :standard},
    {:chat, :hard} => %{specialty: :general, tier: :complex}
  }

  @tier_order [:simple, :standard, :complex]

  @media_specialties [:image, :text_to_video, :image_to_video]

  @doc """
  Finds the model assigned to a media routing slot.
  Media slots use a fixed tier of `:standard` and a direct lookup (no fallback cascade).
  Returns `{:ok, model_key}` or `:no_match`.
  """
  @spec find_media_model(atom()) :: {:ok, String.t()} | :no_match
  def find_media_model(media_specialty) when media_specialty in @media_specialties do
    case fetch_routing_slots([]) do
      [] ->
        :no_match

      slots ->
        case Enum.find(slots, fn s -> s.specialty == media_specialty end) do
          nil -> :no_match
          slot -> {:ok, slot.model.key}
        end
    end
  end

  @doc """
  Finds the best routing-eligible model for the given classification.

  Returns `{:ok, model_key}` or `:no_match`.

  ## Options

  - `:max_tier` - Maximum allowed tier. If the target tier exceeds this,
    it will be capped down. `nil` means no cap.
  - `:required_modalities` - List of required input modality strings
    (e.g., `["image"]`). Slots whose model does not support all required
    modalities are excluded. Defaults to `[]` (no filtering).
  """
  @spec find_model(Classification.t(), keyword()) :: {:ok, String.t()} | :no_match
  def find_model(%Classification{intent: intent, complexity: complexity}, opts \\ []) do
    max_tier = Keyword.get(opts, :max_tier)
    required_modalities = Keyword.get(opts, :required_modalities, [])

    target =
      Map.get(@routing_rules, {intent, complexity}, %{specialty: :general, tier: :standard})

    target = cap_tier(target, max_tier)

    slots =
      required_modalities
      |> fetch_routing_slots()
      |> Enum.reject(fn s -> s.specialty in @media_specialties end)

    Logger.info(
      "AutoRouter ModelMatcher: looking for #{target.specialty}/#{target.tier}" <>
        "#{if max_tier, do: " (max_tier=#{max_tier})", else: ""}" <>
        "#{if required_modalities != [], do: " (modalities=#{inspect(required_modalities)})", else: ""}"
    )

    {slot, match_type} =
      cond do
        s = find_by_specialty_and_tier(slots, target.specialty, target.tier) ->
          {s, :exact}

        s = find_by_specialty(slots, target.specialty) ->
          {s, :specialty_fallback}

        s = find_by_tier(slots, target.tier) ->
          {s, :tier_fallback}

        s = find_any(slots) ->
          {s, :any_fallback}

        true ->
          {nil, :none}
      end

    case slot do
      nil ->
        Logger.info(
          "AutoRouter ModelMatcher: no routing-eligible slot found for #{intent}/#{complexity}"
        )

        :no_match

      slot ->
        Logger.info(
          "AutoRouter ModelMatcher: matched #{slot.model.key} via #{match_type} " <>
            "(slot=#{slot.specialty}/#{slot.tier}, model=#{slot.model.name})"
        )

        {:ok, slot.model.key}
    end
  end

  defp cap_tier(target, nil), do: target

  defp cap_tier(target, max_tier) do
    max_idx = Enum.find_index(@tier_order, &(&1 == max_tier))
    target_idx = Enum.find_index(@tier_order, &(&1 == target.tier))

    if target_idx > max_idx do
      Logger.info("AutoRouter ModelMatcher: capping tier from #{target.tier} to #{max_tier}")

      %{target | tier: max_tier}
    else
      target
    end
  end

  # ============================================================================
  # Slot fetching
  # ============================================================================

  defp fetch_routing_slots(required_modalities) do
    case Magus.Chat.list_routing_slots(authorize?: false) do
      {:ok, slots} ->
        slots
        |> Enum.filter(fn slot -> slot.model.active? end)
        |> filter_by_modalities(required_modalities)

      _ ->
        []
    end
  end

  defp filter_by_modalities(slots, []), do: slots

  defp filter_by_modalities(slots, required) do
    Enum.filter(slots, fn slot ->
      model_modalities = slot.model.input_modalities || ["text"]
      Enum.all?(required, fn mod -> mod in model_modalities end)
    end)
  end

  # ============================================================================
  # Matching functions — progressively less specific
  # ============================================================================

  defp find_by_specialty_and_tier(slots, specialty, tier) do
    Enum.find(slots, fn s ->
      s.specialty == specialty and s.tier == tier
    end)
  end

  defp find_by_specialty(slots, specialty) do
    Enum.find(slots, fn s -> s.specialty == specialty end)
  end

  defp find_by_tier(slots, tier) do
    Enum.find(slots, fn s -> s.tier == tier end)
  end

  defp find_any(slots) do
    List.first(slots)
  end
end
