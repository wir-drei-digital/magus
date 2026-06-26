defmodule MagusWeb.Api.V2.ControllerHelpers do
  @moduledoc """
  Shared helpers for all /api/v2 controllers: param normalization,
  consistent 404 response, and Ash-error to JSON shape conversion.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  require Ash.Query

  alias Magus.Brain
  alias Magus.Brain.BrainResource
  alias MagusWeb.Api.V2.ApiView

  @doc """
  Picks the given atom keys from a string-keyed map, returning an atom-keyed
  map suitable for passing to Ash action attrs.

      iex> to_atom_map(%{"title" => "X"}, [:title, :description])
      %{title: "X"}
  """
  def to_atom_map(params, keys) when is_map(params) and is_list(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.get(params, Atom.to_string(key)) do
        nil -> acc
        v -> Map.put(acc, key, v)
      end
    end)
  end

  @doc """
  Sends a 404 JSON response with code `"not_found"`.
  """
  def not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(ApiView.error("not_found", "Resource not found"))
  end

  @doc """
  Converts an `%Ash.Error.Invalid{}` (or any struct with a `:errors` list of
  exceptions) into a list of `%{field, message}` maps using
  `Exception.message/1` for human-readable strings.
  """
  def ash_errors(%{errors: errors}) when is_list(errors) do
    Enum.map(errors, fn err ->
      %{field: Map.get(err, :field), message: Exception.message(err)}
    end)
  end

  def ash_errors(_), do: []

  @doc """
  Fetches a brain by id-or-slug. If the argument parses as a canonical 36-char
  UUID, calls `Brain.get_brain/2`. Otherwise resolves by slug via a filtered
  read of `BrainResource`. Returns `{:ok, brain}` or `{:error, :not_found}`.

  `Ecto.UUID.cast/1` accepts both canonical 36-char strings and any 16-byte
  binary (treating it as a raw UUID), which means a 16-char slug would be
  misinterpreted as a UUID. The `uuid?/1` predicate requires the canonical
  hyphenated 36-char form.
  """
  def fetch_brain(id_or_slug, actor) when is_binary(id_or_slug) do
    if uuid?(id_or_slug) do
      case Brain.get_brain(id_or_slug, actor: actor) do
        {:ok, brain} -> {:ok, brain}
        {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
        {:error, _} -> {:error, :not_found}
      end
    else
      find_brain_by_slug(id_or_slug, actor)
    end
  end

  def fetch_brain(_, _), do: {:error, :not_found}

  defp find_brain_by_slug(slug, actor) do
    case BrainResource
         |> Ash.Query.filter(slug == ^slug)
         |> Ash.read_one(actor: actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, brain} -> {:ok, brain}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp uuid?(string) when is_binary(string) and byte_size(string) == 36 do
    match?({:ok, _}, Ecto.UUID.cast(string))
  end

  defp uuid?(_), do: false
end
