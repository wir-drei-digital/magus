defmodule Magus.OpenCoreBoundaryTest do
  @moduledoc """
  Guards the open-core boundary established by the Phase 3/4 seam work: no
  module under `lib/magus/` (the core business logic) outside `lib/magus/billing/`
  may resolve `Magus.Billing.*` by `alias`/`import`/`require`/`use` or a remote
  call. Such a reference would break a pure-OSS build the moment `Magus.Billing`
  relocates to `magus_cloud` (magus-mxj5).

  Allowed and therefore ignored:

    * Doc and comment mentions of `Magus.Billing` (parsed away — they live in
      string literals, not code).
    * A bare module-name atom used as a config default, e.g.
      `Application.get_env(:magus, :billing_release_module, Magus.Billing.Release)`
      in `Magus.Release` — it compiles to an atom and needs no compiled module.

  Only `alias`/`import`/`require`/`use` directives and remote calls
  (`Magus.Billing.X.fun(...)`) create the compile-time dependency we forbid.

  Scope note: `lib/magus_web/` is intentionally NOT covered yet — the web layer
  still hosts the Stripe/checkout/marketing scopes carved out by the physical
  split (magus-mxj5). Extend this guard to a target OSS subset of `lib/magus_web`
  as that carve lands.
  """
  use ExUnit.Case, async: true

  @core_lib_root "lib/magus"
  @billing_dir "lib/magus/billing/"

  test "no core lib module resolves Magus.Billing.* (alias/import/use/remote call)" do
    offenders = Enum.flat_map(core_source_files(), &billing_references/1)

    assert offenders == [],
           """
           Core lib (lib/magus/ outside lib/magus/billing/) must not resolve
           Magus.Billing.* — these references break a pure-OSS build once
           Magus.Billing moves to magus_cloud. Route through a seam
           (Application.get_env adapter with a Noop/Identity default) instead.

           Offenders:
           #{Enum.map_join(offenders, "\n", fn {file, kind, mod} -> "  #{file}: #{kind} #{mod}" end)}
           """
  end

  defp core_source_files do
    @core_lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(&1, @billing_dir))
  end

  defp billing_references(file) do
    {_ast, refs} =
      file
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn node, acc ->
        case billing_ref(node) do
          nil -> {node, acc}
          ref -> {node, [{file, elem(ref, 0), elem(ref, 1)} | acc]}
        end
      end)

    refs
  end

  # Remote call: Magus.Billing.X.fun(...) — including the `alias A.B.{C, D}`
  # multi-alias form, which parses as a call on the `:{}` sugar.
  defp billing_ref({{:., _, [{:__aliases__, _, [:Magus, :Billing | _] = parts}, _fun]}, _, _}),
    do: {:call, Enum.join(parts, ".")}

  # alias / import / require / use Magus.Billing(.X)
  defp billing_ref({directive, _, [{:__aliases__, _, [:Magus, :Billing | _] = parts} | _]})
       when directive in [:alias, :import, :require, :use],
       do: {directive, Enum.join(parts, ".")}

  defp billing_ref(_node), do: nil
end
