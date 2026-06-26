defmodule MagusWeb.Admin.ModelsLive.Listing do
  @moduledoc """
  Pure filter / sort / paginate logic for the admin Models index.

  The model catalog is small (admin-curated), so the LiveView loads every row
  once (with usage aggregates) and this module derives the visible page from a
  raw query-param map. Keeping it free of DB and LiveView concerns makes it
  unit-testable and keeps `ModelsLive` focused on rendering + events.
  """

  @page_size 50

  @caps ~w(tools search reasoning image video)
  @sort_fields ~w(name provider status input_cost output_cost usage spend)
  @statuses ~w(all active disabled)

  @type model :: map()
  @type result :: %{
          models: [model()],
          total: non_neg_integer(),
          page: pos_integer(),
          total_pages: pos_integer(),
          page_size: pos_integer(),
          status: String.t(),
          provider: String.t(),
          caps: [String.t()],
          sort: String.t(),
          dir: String.t(),
          provider_options: [String.t()]
        }

  @doc "Number of rows rendered per page."
  def page_size, do: @page_size

  @doc "Allowed capability filter keys (also the Features-column set)."
  def caps, do: @caps

  @doc """
  The provider label shown for a model: linked provider name, then the
  free-text brand, then "-". Mirrors the Provider column exactly so the filter
  dropdown options line up with what the table displays.
  """
  def provider_label(model) do
    case model.model_provider do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> blank_to_dash(Map.get(model, :provider))
    end
  end

  @doc "Usage request count from the loaded aggregate (0 when unloaded/absent)."
  def usage_count(model) do
    case Map.get(model, :usage_count) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc "Total spend (input + output cost sums) as a Decimal."
  def spend(model) do
    Decimal.add(
      decimalish(Map.get(model, :usage_input_cost)),
      decimalish(Map.get(model, :usage_output_cost))
    )
  end

  @doc """
  Filter, sort and paginate `models` according to `params` (string-keyed, from
  the URL). Returns the visible page plus the metadata the view needs to render
  controls and pagination. `provider_options` is derived from the *full* list
  so the dropdown always offers every provider.
  """
  @spec apply([model()], map()) :: result()
  def apply(models, params) when is_list(models) do
    status = normalize(params["status"], @statuses, "all")
    provider = to_string(params["provider"] || "")
    caps = parse_caps(params["caps"])
    sort = normalize(params["sort"], @sort_fields, "name")
    dir = normalize(params["dir"], ~w(asc desc), "asc")

    filtered =
      models
      |> filter_status(status)
      |> filter_provider(provider)
      |> filter_caps(caps)
      |> sort_models(String.to_existing_atom(sort), dir)

    total = length(filtered)
    total_pages = max(div(total + @page_size - 1, @page_size), 1)
    page = params["page"] |> parse_page() |> clamp(1, total_pages)

    page_models = filtered |> Enum.drop((page - 1) * @page_size) |> Enum.take(@page_size)

    %{
      models: page_models,
      total: total,
      page: page,
      total_pages: total_pages,
      page_size: @page_size,
      status: status,
      provider: provider,
      caps: caps,
      sort: sort,
      dir: dir,
      provider_options: provider_options(models)
    }
  end

  @doc "Toggle direction for a column: same column flips, a new column starts asc."
  def toggle_dir(current_sort, current_dir, column) do
    if current_sort == column and current_dir == "asc", do: "desc", else: "asc"
  end

  # ── filtering ──────────────────────────────────────────────────────────────

  defp filter_status(models, "active"), do: Enum.filter(models, & &1.active?)
  defp filter_status(models, "disabled"), do: Enum.filter(models, &(!&1.active?))
  defp filter_status(models, _), do: models

  defp filter_provider(models, ""), do: models

  defp filter_provider(models, provider),
    do: Enum.filter(models, &(provider_label(&1) == provider))

  defp filter_caps(models, []), do: models

  defp filter_caps(models, caps) do
    Enum.filter(models, fn model -> Enum.all?(caps, &has_cap?(model, &1)) end)
  end

  defp has_cap?(model, "tools"), do: model.supports_tools? == true
  defp has_cap?(model, "search"), do: model.supports_search? == true
  defp has_cap?(model, "reasoning"), do: model.supports_reasoning? == true
  defp has_cap?(model, "image"), do: "image" in (model.output_modalities || [])
  defp has_cap?(model, "video"), do: "video" in (model.output_modalities || [])
  defp has_cap?(_model, _), do: false

  # ── sorting ──────────────────────────────────────────────────────────────────
  # Missing numeric keys (e.g. unset cost) always sort last, in both directions.

  defp sort_models(models, field, dir) do
    {present, missing} = Enum.split_with(models, &(sort_key(&1, field) != nil))

    Enum.sort_by(present, &sort_key(&1, field), sort_order(dir)) ++ missing
  end

  defp sort_order("desc"), do: :desc
  defp sort_order(_), do: :asc

  defp sort_key(model, :name), do: model.name |> to_string() |> String.downcase()
  defp sort_key(model, :provider), do: model |> provider_label() |> String.downcase()
  defp sort_key(model, :status), do: if(model.active?, do: 0, else: 1)
  defp sort_key(model, :input_cost), do: parse_cost(Map.get(model, :input_cost))
  defp sort_key(model, :output_cost), do: parse_cost(Map.get(model, :output_cost))
  defp sort_key(model, :usage), do: usage_count(model)
  defp sort_key(model, :spend), do: model |> spend() |> Decimal.to_float()

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp provider_options(models) do
    models |> Enum.map(&provider_label/1) |> Enum.uniq() |> Enum.sort()
  end

  defp parse_caps(nil), do: []
  defp parse_caps(""), do: []

  defp parse_caps(value) when is_binary(value) do
    value |> String.split(",", trim: true) |> Enum.filter(&(&1 in @caps)) |> Enum.uniq()
  end

  defp parse_caps(list) when is_list(list), do: Enum.filter(list, &(&1 in @caps)) |> Enum.uniq()

  defp normalize(value, allowed, default) do
    if is_binary(value) and value in allowed, do: value, else: default
  end

  defp parse_page(nil), do: 1

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 1
    end
  end

  defp parse_page(value) when is_integer(value), do: value
  defp parse_page(_), do: 1

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp parse_cost(nil), do: nil

  defp parse_cost(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_cost(%Decimal{} = d), do: Decimal.to_float(d)
  defp parse_cost(value) when is_number(value), do: value
  defp parse_cost(_), do: nil

  defp decimalish(%Decimal{} = d), do: d
  defp decimalish(n) when is_integer(n), do: Decimal.new(n)
  defp decimalish(n) when is_float(n), do: Decimal.from_float(n)
  defp decimalish(_), do: Decimal.new(0)

  defp blank_to_dash(nil), do: "-"
  defp blank_to_dash(""), do: "-"
  defp blank_to_dash(value), do: value
end
