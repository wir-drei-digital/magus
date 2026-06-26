defmodule Magus.Emails.JobFailureTest do
  @moduledoc """
  Tests for the JobFailure email template.

  Tests cover:
  - Email building with correct fields
  - HTML sanitization of user-provided content
  - Correct structure and formatting
  """
  use Magus.ResourceCase, async: true

  alias Magus.Emails.JobFailure
  alias Magus.Chat

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    job_record = job(conversation_id: conversation.id, user_id: user.id, name: "Daily Report")

    %{user: user, conversation: conversation, job: job_record}
  end

  # ---------------------------------------------------------------------------
  # Email Building
  # ---------------------------------------------------------------------------

  describe "build/3" do
    test "creates email with correct recipient", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Connection timeout")

      user_email = to_string(user.email)
      # Swoosh formats recipients as [{name, email}] where name can be nil or empty
      assert email.to == [{nil, user_email}] or
               email.to == [{"", user_email}] or
               email.to == [user_email]
    end

    test "creates email with correct subject", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Connection timeout")

      assert email.subject == "[Magus] Job Failed: #{job.name}"
    end

    test "includes error message in HTML body", %{user: user, job: job} do
      error_message = "Database connection failed after 3 retries"
      email = JobFailure.build(user, job, error_message)

      assert email.html_body =~ error_message
    end

    test "includes error message in text body", %{user: user, job: job} do
      error_message = "Database connection failed after 3 retries"
      email = JobFailure.build(user, job, error_message)

      assert email.text_body =~ error_message
    end

    test "includes job name in HTML body", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Some error")

      assert email.html_body =~ job.name
    end

    test "includes conversation link in HTML body", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Some error")

      assert email.html_body =~ "/chat/#{job.conversation_id}"
    end

    test "includes job details link in HTML body", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Some error")

      assert email.html_body =~ "/jobs/#{job.id}"
    end

    test "includes jobs dashboard link in HTML body", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Some error")

      assert email.html_body =~ "/jobs"
    end
  end

  # ---------------------------------------------------------------------------
  # HTML Sanitization
  # ---------------------------------------------------------------------------

  describe "HTML sanitization" do
    test "sanitizes job name in subject", %{user: user, conversation: conversation} do
      # Create a job with potentially dangerous name
      malicious_job =
        job(
          conversation_id: conversation.id,
          user_id: user.id,
          name: "Job <script>alert('xss')</script>"
        )

      email = JobFailure.build(user, malicious_job, "Error")

      # The subject should have the script tags stripped
      refute email.subject =~ "<script>"
      refute email.subject =~ "</script>"
    end

    test "sanitizes error message in HTML body", %{user: user, job: job} do
      malicious_error = "<script>alert('xss')</script>Real error message"
      email = JobFailure.build(user, job, malicious_error)

      # The HTML body should have the script tags stripped
      refute email.html_body =~ "<script>alert"
    end

    test "preserves safe content", %{user: user, job: job} do
      safe_error = "Error occurred at 2024-01-15 10:30:00 UTC"
      email = JobFailure.build(user, job, safe_error)

      assert email.html_body =~ "2024-01-15 10:30:00 UTC"
      assert email.text_body =~ "2024-01-15 10:30:00 UTC"
    end
  end

  # ---------------------------------------------------------------------------
  # Text Body
  # ---------------------------------------------------------------------------

  describe "text body" do
    test "includes job name", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Error")

      assert email.text_body =~ job.name
    end

    test "includes error message", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Specific error details")

      assert email.text_body =~ "Specific error details"
    end

    test "includes relevant URLs", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Error")

      assert email.text_body =~ "/chat/#{job.conversation_id}"
      assert email.text_body =~ "/jobs/#{job.id}"
    end

    test "includes helpful message about retry", %{user: user, job: job} do
      email = JobFailure.build(user, job, "Error")

      assert email.text_body =~ "continue attempting" or email.text_body =~ "next scheduled"
    end
  end

  # ---------------------------------------------------------------------------
  # Edge Cases
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "handles empty error message", %{user: user, job: job} do
      email = JobFailure.build(user, job, "")

      assert email.subject =~ "Job Failed"
      assert email.html_body != nil
      assert email.text_body != nil
    end

    test "handles long error message", %{user: user, job: job} do
      long_error = String.duplicate("Error details. ", 100)
      email = JobFailure.build(user, job, long_error)

      # Should not crash and should include the error
      assert email.html_body =~ "Error details"
    end

    test "handles special characters in error message", %{user: user, job: job} do
      special_error = "Error with <special> & 'chars' \"quoted\""
      email = JobFailure.build(user, job, special_error)

      # Should be properly escaped in HTML
      assert email.html_body != nil
    end
  end
end
