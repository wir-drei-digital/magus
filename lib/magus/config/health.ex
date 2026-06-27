defmodule Magus.Config.Health do
  @moduledoc """
  Self-host configuration diagnostic.

  Reports required boot configuration and optional capabilities so an operator
  can see at a glance what is set, missing, or simply not configured. It never
  raises or alters boot: it reads already-resolved application config and
  environment variables.

  Surfaced by `mix magus.doctor` in development. In a release without Mix, call
  `report/0` and write the returned string to standard output (see
  `docker-compose.selfhost.yml` for the exact `bin/magus eval` one-liner).
  """

  @type status :: :ok | :missing | :not_configured
  @type check :: %{
          key: atom(),
          label: String.t(),
          category: atom(),
          required?: boolean(),
          status: status(),
          detail: String.t()
        }

  # An LLM key from any one of these enables the app's core function.
  @llm_keys ~w(OPENROUTER_API_KEY OPENAI_API_KEY AIML_API_KEY)

  # Display order for grouped output.
  @category_order [:core, :ai, :tools, :infra, :integrations]

  @doc """
  Classifies a configuration value's presence into a status:

    * present -> `:ok`
    * absent and required -> `:missing`
    * absent and optional -> `:not_configured`
  """
  @spec classify(present? :: boolean(), required? :: boolean()) :: status()
  def classify(true, _required?), do: :ok
  def classify(false, true), do: :missing
  def classify(false, false), do: :not_configured

  @doc "Returns every configuration check with its current status."
  @spec checks() :: [check()]
  def checks do
    [
      check(
        :database,
        "Database (Postgres)",
        :core,
        true,
        repo_configured?(),
        "Set DATABASE_URL (production); dev/test use config files."
      ),
      check(
        :secret_key_base,
        "Phoenix secret key base",
        :core,
        true,
        endpoint_secret?(),
        "Set SECRET_KEY_BASE (generate with `mix phx.gen.secret`)."
      ),
      check(
        :token_signing_secret,
        "Auth token signing secret",
        :core,
        true,
        app_env?(:token_signing_secret),
        "Set TOKEN_SIGNING_SECRET (generate with `mix phx.gen.secret`)."
      ),
      check(
        :integration_encryption_key,
        "Integration secret encryption key",
        :core,
        false,
        env?("INTEGRATION_ENCRYPTION_KEY"),
        "Set INTEGRATION_ENCRYPTION_KEY to store external integration secrets."
      ),
      check(
        :llm_provider,
        "LLM provider key",
        :ai,
        false,
        any_env?(@llm_keys),
        "Set at least one of: #{Enum.join(@llm_keys, ", ")}."
      ),
      check(
        :search,
        "Web search",
        :tools,
        false,
        capability?(Magus.Capabilities.Search),
        "Set EXA_API_KEY to enable the web_search tool."
      ),
      check(
        :crawl,
        "Web crawl",
        :tools,
        false,
        capability?(Magus.Capabilities.Crawl),
        "Set SPIDER_API_KEY to enable the crawl tool."
      ),
      check(
        :sandbox,
        "Sandbox code execution",
        :tools,
        false,
        sandbox_configured?(),
        "Set SANDBOX_PROVIDER + its API key (daytona or sprites)."
      ),
      storage_check(),
      check(
        :mail,
        "Email delivery",
        :infra,
        false,
        mail_configured?(),
        "Set POSTMARK_API_KEY or configure a Swoosh adapter for real delivery."
      ),
      check(
        :super_brain,
        "Super Brain (FalkorDB)",
        :infra,
        false,
        super_brain_enabled?(),
        "Set SUPER_BRAIN_ENABLED=true + FALKORDB_* to enable the knowledge graph."
      ),
      check(
        :oauth_google,
        "Google OAuth",
        :integrations,
        false,
        env?("GOOGLE_CLIENT_ID"),
        "Set GOOGLE_CLIENT_ID/SECRET for Google Calendar integration."
      ),
      check(
        :oauth_notion,
        "Notion OAuth",
        :integrations,
        false,
        env?("NOTION_CLIENT_ID"),
        "Set NOTION_CLIENT_ID/SECRET for Notion integration."
      )
    ]
  end

  @doc "True unless some required check is missing."
  @spec all_required_ok?() :: boolean()
  def all_required_ok? do
    Enum.all?(checks(), fn c -> not c.required? or c.status == :ok end)
  end

  @doc """
  Renders the configuration report as a human-readable string. Pure: the caller
  decides where to write it. `mix magus.doctor` prints it via `Mix.shell`.
  """
  @spec report() :: String.t()
  def report do
    grouped = Enum.group_by(checks(), & &1.category)

    body =
      @category_order
      |> Enum.filter(&Map.has_key?(grouped, &1))
      |> Enum.map_join("\n", fn category -> render_group(category, grouped[category]) end)

    footer =
      if all_required_ok?() do
        "All required configuration is present."
      else
        "MISSING required configuration — see items marked (required) above."
      end

    """
    Magus configuration health
    ==============================
    #{body}

    #{footer}
    """
  end

  # --- private ---

  defp render_group(category, group) do
    lines =
      Enum.map_join(group, "\n", fn c ->
        line = "  #{icon(c.status)} #{c.label}#{required_marker(c)}"
        if c.status == :ok, do: line, else: line <> "\n        #{c.detail}"
      end)

    "\n[#{category}]\n" <> lines
  end

  defp check(key, label, category, required?, present?, detail) do
    %{
      key: key,
      label: label,
      category: category,
      required?: required?,
      status: classify(present?, required?),
      detail: detail
    }
  end

  # Storage is backend-aware (magus-i5k6): local disk is always "ok" (the
  # zero-dependency self-host default), while the S3 backend needs AWS_BUCKET.
  defp storage_check do
    case Magus.Files.Storage.backend() do
      :s3 ->
        check(
          :storage,
          "File storage (object / S3)",
          :infra,
          false,
          env?("AWS_BUCKET"),
          "Set AWS_BUCKET + credentials to persist uploaded files."
        )

      _ ->
        check(
          :storage,
          "File storage (local disk)",
          :infra,
          false,
          true,
          "Local disk at priv/static/uploads (single-node; mount a volume to persist). Set AWS_BUCKET or STORAGE_BACKEND=s3 for object storage."
        )
    end
  end

  defp env?(name), do: present?(System.get_env(name))
  defp any_env?(names), do: Enum.any?(names, &env?/1)
  defp app_env?(key), do: present?(Application.get_env(:magus, key))

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp repo_configured? do
    cfg = Application.get_env(:magus, Magus.Repo, [])
    present?(cfg[:url]) or present?(cfg[:database])
  end

  defp endpoint_secret? do
    Application.get_env(:magus, MagusWeb.Endpoint, [])
    |> Keyword.get(:secret_key_base)
    |> present?()
  end

  defp capability?(mod) do
    function_exported?(mod, :configured?, 0) and mod.configured?()
  rescue
    _ -> false
  end

  defp sandbox_configured? do
    Magus.Sandbox.Provider.configured?()
  rescue
    _ -> false
  end

  defp mail_configured? do
    adapter = Application.get_env(:magus, Magus.Mailer, [])[:adapter]
    env?("POSTMARK_API_KEY") or adapter not in [nil, Swoosh.Adapters.Local, Swoosh.Adapters.Test]
  end

  defp super_brain_enabled? do
    Application.get_env(:magus, :super_brain_enabled, false) == true
  end

  defp icon(:ok), do: "[ok]"
  defp icon(:missing), do: "[MISSING]"
  defp icon(:not_configured), do: "[--]"

  defp required_marker(%{required?: true}), do: " (required)"
  defp required_marker(_), do: ""
end
