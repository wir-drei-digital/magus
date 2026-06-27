defmodule Magus.Models.Resolution do
  @moduledoc """
  The result of resolving a model selection: the resolved model plus
  orthogonal facts about how it was selected and whose credential pays.

  Facts only, never billing policy (billability is derived downstream in
  `Magus.Usage.PolicyEnforcer`). No secrets: carries `provider_id`, never a
  `Magus.Models.Provider` struct.
  """

  @type selection_source :: :explicit | :auto | :role_default | :product_default

  @type t :: %__MODULE__{
          model: struct() | nil,
          selection_source: selection_source(),
          requested_selection: nil | %{by: :id | :key, value: term()},
          provider_id: binary() | nil,
          access_source: :global | :owned | :workspace_shared,
          credential_owner_user_id: binary() | nil,
          cost_source: :platform_key | :byok
        }

  @enforce_keys [:model, :selection_source]
  defstruct model: nil,
            selection_source: :product_default,
            requested_selection: nil,
            provider_id: nil,
            access_source: :global,
            credential_owner_user_id: nil,
            cost_source: :platform_key

  @doc """
  True when an explicit selection was requested but the resolved model is not
  it (the request degraded to an inherited fallback).
  """
  @spec degraded?(t()) :: boolean()
  def degraded?(%__MODULE__{requested_selection: nil}), do: false

  def degraded?(%__MODULE__{requested_selection: %{by: :id, value: id}, model: model}),
    do: model_field(model, :id) != id

  def degraded?(%__MODULE__{requested_selection: %{by: :key, value: key}, model: model}),
    do: model_field(model, :key) != key

  defp model_field(%{} = model, field), do: Map.get(model, field)
  defp model_field(_, _), do: nil
end
