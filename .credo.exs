# Credo configuration.
#
# Checks come from base Credo plus two plugins (declared in mix.exs):
#
#   * ExSlop   catches AI-generated code "slop" (blanket rescues, N+1 queries,
#              non-idiomatic Enum usage, narrator comments, ...).
#   * AshCredo Ash-framework anti-pattern checks (missing domain, authorize?:
#              false, sensitive attribute exposure, ...). Checks that introspect
#              compiled DSL modules need the project compiled first, so run
#              credo via the `lint` alias (compile + credo) or `mix compile`
#              beforehand.
#
# IMPORTANT: do NOT pin an explicit `checks.enabled` list here (e.g. by running
# `mix credo.gen.config` and keeping its output). Both plugins inject their
# checks through Credo's `checks.extra` merge, and an explicit `enabled` list
# overrides and discards every plugin-contributed check. Tune individual checks
# under `checks.disabled` / `checks.extra` instead. Base Credo checks run with
# their built-in defaults.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [{ExSlop, []}, {AshCredo, []}],
      checks: %{
        extra: [],
        disabled: []
      }
    }
  ]
}
