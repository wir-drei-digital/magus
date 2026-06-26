defmodule Mix.Tasks.Magus.Doctor do
  @shortdoc "Reports Magus self-host configuration health"
  @moduledoc """
  Prints the Magus configuration health report: required boot config and
  optional capabilities, each shown as ok / missing / not-configured.

      mix magus.doctor

  Exits with status 1 when any required configuration is missing, so it can
  gate a deploy. In a release without Mix, use the `bin/magus eval` one-liner
  documented in `docker-compose.selfhost.yml`.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info(Magus.Config.Health.report())

    unless Magus.Config.Health.all_required_ok?() do
      exit({:shutdown, 1})
    end
  end
end
