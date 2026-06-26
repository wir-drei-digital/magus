defmodule Magus.Emails.JobFailure do
  @moduledoc """
  Email template for notifying users when a scheduled job fails after multiple retries.

  This email is sent by the job execution system when a job has exhausted
  all retry attempts and needs user attention.
  """

  import Swoosh.Email

  @doc """
  Builds a job failure notification email.

  ## Parameters

    * `user` - The user struct with at least an `email` field
    * `job` - The job struct that failed
    * `error_message` - Human-readable error description

  ## Returns

  A Swoosh.Email struct ready to be delivered.
  """
  def build(user, job, error_message) do
    user_email = to_string(user.email)
    job_name = to_string(job.name)

    new()
    |> to(user_email)
    |> from({"Magus", "noreply@magus.digital"})
    |> subject("[Magus] Job Failed: #{HtmlSanitizeEx.strip_tags(job_name)}")
    |> html_body(build_html_body(job, error_message))
    |> text_body(build_text_body(job, error_message))
  end

  defp build_html_body(job, error_message) do
    job_name = HtmlSanitizeEx.strip_tags(to_string(job.name))
    safe_error = HtmlSanitizeEx.strip_tags(to_string(error_message))

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
    </head>
    <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
      <h2 style="color: #dc3545;">Job Failed</h2>

      <p>Your scheduled job <strong>#{job_name}</strong> has failed after multiple retry attempts.</p>

      <div style="background: #f8f9fa; padding: 16px; border-radius: 8px; margin: 20px 0;">
        <p style="margin: 0;"><strong>Error:</strong></p>
        <pre style="background: #fff; padding: 12px; border-radius: 4px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word;">#{safe_error}</pre>
      </div>

      <p>
        <a href="#{app_url()}/chat/#{job.conversation_id}" style="display: inline-block; padding: 10px 20px; background: #0066cc; color: #fff; text-decoration: none; border-radius: 4px; margin-right: 10px;">Open conversation</a>
        <a href="#{app_url()}/jobs/#{job.id}" style="display: inline-block; padding: 10px 20px; background: #6c757d; color: #fff; text-decoration: none; border-radius: 4px;">View job details</a>
      </p>

      <p style="color: #666; font-size: 12px; margin-top: 30px;">
        The job will continue attempting to run at its next scheduled time.
        To stop the job, visit your <a href="#{app_url()}/jobs" style="color: #0066cc;">jobs dashboard</a>.
      </p>
    </body>
    </html>
    """
  end

  defp build_text_body(job, error_message) do
    job_name = to_string(job.name)
    error_msg = to_string(error_message)

    """
    Job Failed: #{job_name}

    Your scheduled job has failed after multiple retry attempts.

    Error: #{error_msg}

    Open conversation: #{app_url()}/chat/#{job.conversation_id}
    View job details: #{app_url()}/jobs/#{job.id}

    The job will continue attempting to run at its next scheduled time.
    To stop the job, visit your jobs dashboard at #{app_url()}/jobs
    """
  end

  defp app_url do
    Application.get_env(:magus, :app_url, "http://localhost:4000")
  end
end
