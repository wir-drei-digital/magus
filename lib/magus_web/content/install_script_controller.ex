defmodule MagusWeb.Content.InstallScriptController do
  use MagusWeb, :controller

  @cli_repo "wir-drei-digital/magus-cli"
  @install_script_url "https://raw.githubusercontent.com/#{@cli_repo}/main/install.sh"

  @doc """
  Vanity redirect for the magus CLI installer.

  Lets users run:

      curl -fsSL https://magus.digital/install.sh | sh

  Always points at the latest install.sh on the `main` branch of the CLI
  repo, so we never need to redeploy the backend when the installer
  changes.
  """
  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> redirect(external: @install_script_url)
  end
end
