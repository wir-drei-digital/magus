defmodule Magus.Agents.Tools.Sandbox.InstallPackages do
  @moduledoc """
  Jido tool for installing Python packages in a sandbox environment.

  This tool installs packages via uv (a fast Python package manager), which
  persist for the duration of the sandbox session.
  """

  use Jido.Action,
    name: "install_packages",
    description: """
    Install Python packages in the sandbox environment. Packages persist for the session.

    Use this BEFORE run_code when you need libraries that aren't in the standard library.

    Common package recommendations by use case:
    - Data analysis: pandas, openpyxl (Excel read/write), xlrd (legacy Excel)
    - Data visualization: matplotlib, seaborn, plotly
    - Scientific computing: numpy, scipy, sympy (symbolic math)
    - Machine learning: scikit-learn, xgboost
    - PDF generation: weasyprint, fpdf
    - Image processing: pillow
    - Date handling: python-dateutil
    - JSON/YAML: pyyaml

    Tips:
    - Install all needed packages in one call for efficiency
    - Already-installed packages are skipped automatically (no re-download)
    - Package installation requires network access (restricted to PyPI)
    """,
    schema: [
      packages: [
        type: {:list, :string},
        required: true,
        doc: "List of Python packages to install (e.g., [\"pandas\", \"matplotlib\"])"
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Sandbox.Orchestrator

  @timeout_ms 180_000

  @doc "User-friendly display name shown in the UI"
  def display_name, do: "Installing packages..."

  # Internal client timeout is @timeout_ms (180s); runner backstop sits above it.
  def execution_timeout_ms, do: :timer.minutes(5)

  @doc "Generate a human-readable summary of output"
  def summarize_output(%{success: true, packages: packages}) when is_list(packages) do
    "Installed #{length(packages)} package(s)"
  end

  def summarize_output(%{success: true}), do: "Packages installed"

  def summarize_output(%{success: false, error_type: type}) when is_binary(type),
    do: "Failed: #{type}"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        install_packages(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp install_packages(conversation_id, user_id, params, context) do
    packages = params["packages"] || []

    if packages == [] do
      {:ok,
       %{
         success: false,
         error_type: "validation_error",
         error: "No packages specified",
         hint: "Provide a list of package names to install."
       }}
    else
      # Step 0: Setup
      Signals.emit_tool_step_start(context, 0, "Setting up sandbox")

      opts = [
        timeout_ms: @timeout_ms,
        user_id: user_id
      ]

      Signals.emit_tool_step_complete(context, 0)

      # Step 1: Install
      package_list = Enum.join(packages, ", ")
      Signals.emit_tool_step_start(context, 1, "Installing: #{package_list}")

      case Orchestrator.install_packages(conversation_id, packages, opts) do
        {:ok, result} ->
          summary =
            if result.exit_code == 0,
              do: "#{length(packages)} package(s) installed",
              else: "exit #{result.exit_code}"

          Signals.emit_tool_step_complete(context, 1, :complete, summary)
          {:ok, format_success(result, packages)}

        {:error, :timeout, _partial} ->
          Signals.emit_tool_step_complete(context, 1, :error, "Timed out")
          {:ok, format_timeout(packages)}

        {:error, :not_configured, _} ->
          Signals.emit_tool_step_complete(context, 1, :error, "Not configured")

          {:ok,
           %{
             success: false,
             error_type: "configuration_error",
             error: "Package installation is not configured. Please contact support.",
             hint: "The sandbox service is not available."
           }}

        {:error, :sprite_not_found, _} ->
          Signals.emit_tool_step_complete(context, 1, :error, "Sandbox unavailable")

          {:ok,
           %{
             success: false,
             error_type: "sandbox_unavailable",
             error: "The sandbox is temporarily unavailable. Please try again.",
             hint: "The sandbox session may have expired. A new one will be created on retry."
           }}

        {:error, _type, details} ->
          Signals.emit_tool_step_complete(context, 1, :error, "Failed")
          {:ok, format_error(details, packages)}
      end
    end
  end

  defp format_success(result, packages) do
    %{
      success: result.exit_code == 0,
      packages: packages,
      stdout: result.stdout,
      stderr: result.stderr,
      exit_code: result.exit_code,
      duration_ms: result.duration_ms,
      hint:
        if result.exit_code == 0 do
          "Packages are now available. Use run_code to import and use them."
        else
          "Some packages may have failed to install. Check the output for details."
        end
    }
  end

  defp format_timeout(packages) do
    %{
      success: false,
      packages: packages,
      error_type: "timeout",
      error: "Package installation timed out.",
      hint:
        "Try installing fewer packages at once. Large packages like torch or tensorflow may need extra time."
    }
  end

  defp format_error(details, packages) when is_map(details) do
    %{
      success: false,
      packages: packages,
      stdout: Map.get(details, :stdout, "") || "",
      stderr: Map.get(details, :stderr, "") || inspect(details),
      error_type: "installation_error",
      hint: "Check if the package names are correct. Some packages may not be available on PyPI."
    }
  end

  defp format_error(details, packages) do
    %{
      success: false,
      packages: packages,
      stderr: inspect(details),
      error_type: "unknown_error",
      hint: "An unexpected error occurred. Try again or check package names."
    }
  end
end
