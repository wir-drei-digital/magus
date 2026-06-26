defmodule Magus.Agents.Tools.Email.SendEmail do
  @moduledoc """
  Tool for sending emails to users from AI agents.

  This tool implements comprehensive security measures:
  - Only sends to user's registered email address (no arbitrary recipients)
  - HTML content sanitized with HtmlSanitizeEx
  - Agent content wrapped in system template
  - Content validation (length limits, prohibited patterns)
  - Rate limiting (max 1 email per 15 minutes per user)
  - Audit logging for all sent emails

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Email.SendEmail]
      tool_contexts = %{
        Magus.Agents.Tools.Email.SendEmail => %{
          user_id: user.id,
          conversation_id: conversation.id,
          job: job  # Optional, if triggered by a job
        }
      }
  """

  use Jido.Action,
    name: "send_email",
    description: """
    Send an email to the user. The email will be sent to the user's registered email address only.
    The body should be in Markdown format - it will be converted to HTML.
    Use this for important notifications, scheduled reminders, and updates the user requested.
    """,
    schema: [
      subject: [
        type: :string,
        required: true,
        doc: "Email subject line (max 100 characters)"
      ],
      body: [
        type: :string,
        required: true,
        doc: "Email body in Markdown format. Will be converted to HTML and sanitized."
      ]
    ]

  require Logger

  alias Magus.Mailer

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_context_value: 2, ai_actor: 0, get_param: 2]

  # Configuration helpers - read at runtime for flexibility
  defp rate_limit_minutes do
    Application.get_env(:magus, __MODULE__)[:rate_limit_minutes] || 15
  end

  defp max_subject_length do
    Application.get_env(:magus, __MODULE__)[:max_subject_length] || 100
  end

  defp max_body_length do
    Application.get_env(:magus, __MODULE__)[:max_body_length] || 10_000
  end

  defp mdex_opts do
    [extension: [table: true, strikethrough: true, autolink: true, tasklist: true]]
  end

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Sending email..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{status: "sent", subject: subject}), do: "Sent: #{subject}"
  def summarize_output(%{status: "sent"}), do: "Email sent"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id, :conversation_id]) do
      {:ok, ctx} ->
        job = get_context_value(context, :job)
        subject = get_param(params, :subject)
        body = get_param(params, :body)
        send_email(subject, body, ctx, job)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp send_email(subject, body, ctx, job) do
    case Magus.Accounts.get_user(ctx.user_id, actor: ai_actor()) do
      {:ok, user} ->
        do_send_email(subject, body, ctx, user, job)

      {:error, _} ->
        {:ok, %{error: "User not found. Unable to send email."}}
    end
  end

  defp do_send_email(subject, body, ctx, user, job) do
    # Validate content BEFORE checking rate limit to avoid penalizing users for invalid content
    with :ok <- validate_subject(subject),
         :ok <- validate_body(body),
         :ok <- check_rate_limit(ctx.user_id) do
      email = build_email(user, subject, body, job)

      case Mailer.deliver(email) do
        {:ok, _} ->
          log_email_sent(user, job, subject, body)
          record_rate_limit(ctx.user_id)

          {:ok,
           %{
             status: "sent",
             to: to_string(user.email),
             subject: subject
           }}

        {:error, reason} ->
          Logger.error("Email delivery failed: #{inspect(reason)}")
          {:ok, %{error: "Failed to send email. Please try again later."}}
      end
    else
      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  # Rate Limiting
  # Uses cache TTL for automatic expiration - no need to store/check timestamps

  defp check_rate_limit(user_id) do
    key = "email_rate_limit:#{user_id}"

    if Magus.Cache.exists?(key) do
      {:error,
       "Rate limit exceeded. You can send another email in up to #{rate_limit_minutes()} minute(s)."}
    else
      :ok
    end
  end

  defp record_rate_limit(user_id) do
    key = "email_rate_limit:#{user_id}"
    # TTL handles expiration - just store a marker value
    Magus.Cache.put(key, true, ttl: rate_limit_minutes() * 60)
  end

  # Validation

  defp validate_subject(subject) do
    max_len = max_subject_length()

    cond do
      String.length(subject) > max_len ->
        {:error, "Subject too long (max #{max_len} characters)"}

      String.contains?(subject, ["\r", "\n"]) ->
        {:error, "Subject cannot contain newlines"}

      true ->
        :ok
    end
  end

  defp validate_body(body) do
    max_len = max_body_length()

    cond do
      String.length(body) > max_len ->
        {:error, "Email body too long (max #{max_len} characters)"}

      contains_prohibited_content?(body) ->
        {:error, "Email body contains prohibited content"}

      # Also check the rendered HTML to catch entity-encoded attacks
      contains_prohibited_content_in_html?(body) ->
        {:error, "Email body contains prohibited content"}

      true ->
        :ok
    end
  end

  # Check for prohibited content in raw markdown input
  defp contains_prohibited_content?(body) do
    body_lower = String.downcase(body)

    # Simple string patterns that are always dangerous
    simple_patterns = [
      "<script",
      "<iframe",
      "javascript:",
      "vbscript:",
      "onclick",
      "onerror",
      "onload"
    ]

    # Check simple patterns first
    has_simple_match = Enum.any?(simple_patterns, &String.contains?(body_lower, &1))

    # Check for data: URI scheme more carefully to avoid false positives
    # Data URIs typically look like "data:text/html," or "data:image/png;base64,"
    has_data_uri = Regex.match?(~r/data:\s*(text|image|application|audio|video)\//, body_lower)

    has_simple_match or has_data_uri
  end

  # Check for prohibited content in rendered HTML output
  # This catches entity-encoded attacks that bypass raw text checks
  defp contains_prohibited_content_in_html?(markdown_body) do
    html = MDEx.to_html!(markdown_body, mdex_opts())
    contains_prohibited_content?(html)
  rescue
    # If markdown parsing fails, reject the content (fail-secure)
    _ -> true
  end

  # Email Building

  defp build_email(user, subject, agent_content, job) do
    import Swoosh.Email

    user_email = to_string(user.email)
    sanitized_body = sanitize_html(agent_content)
    wrapped_content = wrap_in_template(sanitized_body, user_email, job)

    new()
    |> to(user_email)
    |> from({"Magus", "noreply@magus.digital"})
    |> subject("#{sanitize_subject(subject)}")
    |> html_body(wrapped_content)
    |> text_body(generate_text_version(agent_content))
  end

  defp sanitize_html(markdown_content) do
    markdown_content
    |> MDEx.to_html!(mdex_opts())
    |> HtmlSanitizeEx.basic_html()
  end

  defp sanitize_subject(subject) do
    subject
    |> String.slice(0, max_subject_length())
    |> String.replace(~r/[\r\n]/, " ")
  end

  defp wrap_in_template(sanitized_content, user_email, job) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
    </head>
    <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">

      <p style="color: #666; font-size: 12px; margin-bottom: 20px;">
        This is an automated message from your AI Assistant.
      </p>

      <hr style="border: none; border-top: 1px solid #eee; margin: 20px 0;">

      <div style="line-height: 1.6;">
        #{sanitized_content}
      </div>

      <hr style="border: none; border-top: 1px solid #eee; margin: 20px 0;">

      #{job_footer(job)}

      <p style="color: #999; font-size: 11px; margin-top: 20px;">
        This email was sent to #{HtmlSanitizeEx.strip_tags(user_email)} from Magus.<br>
        <a href="#{app_url()}/settings" style="color: #666;">Manage email preferences</a>
        #{if job, do: " | <a href=\"#{app_url()}/jobs\" style=\"color: #666;\">Manage jobs</a>", else: ""}
      </p>

    </body>
    </html>
    """
  end

  defp job_footer(nil), do: ""

  defp job_footer(job) do
    job_name = HtmlSanitizeEx.strip_tags(to_string(job.name))

    """
    <div style="background: #f8f9fa; padding: 16px; border-radius: 8px; font-size: 13px; margin: 20px 0;">
      <p style="margin: 0 0 12px 0;">
        <strong>Job:</strong> #{job_name}
      </p>
      <p style="margin: 0 0 12px 0; text-align: center;">
        <a href="#{app_url()}/chat/#{job.conversation_id}" style="display: inline-block; background: #0066cc; color: #ffffff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-weight: 500;">Reply</a>
      </p>
      <p style="margin: 0; color: #666; font-size: 12px;">
        To stop these emails, reply "Stop the #{job_name} job" in the chat,
        or <a href="#{app_url()}/jobs/#{job.id}" style="color: #0066cc;">manage this job</a>.
      </p>
    </div>
    """
  end

  defp generate_text_version(markdown) do
    # Simple text version - strip markdown formatting
    markdown
    |> String.replace(~r/\*\*(.+?)\*\*/, "\\1")
    |> String.replace(~r/\*(.+?)\*/, "\\1")
    |> String.replace(~r/\[(.+?)\]\(.+?\)/, "\\1")
    |> String.replace(~r/^#+\s*/m, "")
  end

  defp app_url do
    Application.get_env(:magus, :app_url, "http://localhost:4000")
  end

  # Audit Logging

  defp log_email_sent(user, job, subject, content) do
    Logger.info("Email sent",
      user_id: user.id,
      user_email: user.email,
      job_id: job && job.id,
      job_name: job && job.name,
      subject: subject,
      content_length: String.length(content),
      timestamp: DateTime.utc_now()
    )
  end
end
