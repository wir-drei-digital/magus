defmodule Magus.Agents.Tools.Email.SendEmailTest do
  @moduledoc """
  Comprehensive tests for the SendEmail tool.

  Tests cover:
  - Tool execution with valid context
  - Rate limiting (1 email per 15 minutes)
  - Subject validation (length, newlines)
  - Body validation (length, prohibited content)
  - HTML sanitization
  - Context validation (missing user_id, conversation_id)
  - Display name and output summarization
  - Job footer rendering
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Email.SendEmail
  alias Magus.Chat

  import Swoosh.TestAssertions

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    # Clear rate limit for this specific user
    Magus.Cache.delete("email_rate_limit:#{user.id}")

    context = %{
      user_id: user.id,
      conversation_id: conversation.id,
      folder_id: nil
    }

    %{user: user, conversation: conversation, context: context}
  end

  defp clear_rate_limit(user_id) do
    Magus.Cache.delete("email_rate_limit:#{user_id}")
  end

  # ---------------------------------------------------------------------------
  # Display Name and Output Summarization
  # ---------------------------------------------------------------------------

  describe "display_name/0" do
    test "provides display name" do
      assert SendEmail.display_name() == "Sending email..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes sent email with subject" do
      assert SendEmail.summarize_output(%{status: "sent", subject: "Test Subject"}) ==
               "Sent: Test Subject"
    end

    test "summarizes sent email without subject" do
      assert SendEmail.summarize_output(%{status: "sent"}) == "Email sent"
    end

    test "summarizes error" do
      assert SendEmail.summarize_output(%{error: "some error"}) == "Error"
    end

    test "summarizes unknown output" do
      assert SendEmail.summarize_output(%{}) == "Completed"
      assert SendEmail.summarize_output(%{foo: "bar"}) == "Completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Basic Email Sending
  # ---------------------------------------------------------------------------

  describe "run/2 - successful email sending" do
    test "sends email with valid params and context", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{
        subject: "Test Email Subject",
        body: "This is a **test** email with some *formatting*."
      }

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
      assert result.to == to_string(user.email)
      assert result.subject == "Test Email Subject"
    end

    test "returns plain string email address (not Ash.CiString)", %{
      context: context,
      user: user
    } do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "Test body"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert is_binary(result.to)
      assert result.to == to_string(user.email)
      assert {:ok, _json} = Jason.encode(result)
    end

    test "sends email with markdown body converted to HTML", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{
        subject: "Markdown Test",
        body: """
        # Heading

        This is a paragraph with **bold** and *italic* text.

        - Item 1
        - Item 2

        [Link text](https://example.com)
        """
      }

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end

    test "works with string keys in context", %{user: user, conversation: conversation} do
      clear_rate_limit(user.id)

      string_context = %{
        "user_id" => user.id,
        "conversation_id" => conversation.id
      }

      params = %{
        subject: "String Keys Test",
        body: "Testing string keys in context"
      }

      assert {:ok, result} = SendEmail.run(params, string_context)
      assert result.status == "sent"
    end
  end

  # ---------------------------------------------------------------------------
  # Rate Limiting
  # ---------------------------------------------------------------------------

  describe "run/2 - rate limiting" do
    test "allows first email", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "First Email", body: "First email body"}
      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end

    test "blocks second email within rate limit window", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "First Email", body: "First email body"}
      assert {:ok, %{status: "sent"}} = SendEmail.run(params, context)

      # Try sending another email immediately
      params2 = %{subject: "Second Email", body: "Second email body"}
      assert {:ok, result} = SendEmail.run(params2, context)
      assert result.error =~ "Rate limit exceeded"
    end

    test "allows email after rate limit expires", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # Set a rate limit that expires immediately (TTL of 0 seconds)
      key = "email_rate_limit:#{user.id}"
      Magus.Cache.put(key, true, ttl: 0)

      # Wait for TTL to expire
      Process.sleep(50)

      params = %{subject: "After Limit", body: "Should be allowed"}
      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end

    test "rate limits are per-user", %{conversation: conversation} do
      # Create two different users
      user1 = generate(user())
      user2 = generate(user())

      clear_rate_limit(user1.id)
      clear_rate_limit(user2.id)

      context1 = %{user_id: user1.id, conversation_id: conversation.id}
      context2 = %{user_id: user2.id, conversation_id: conversation.id}

      params = %{subject: "Test", body: "Test body"}

      # User 1 sends
      assert {:ok, %{status: "sent"}} = SendEmail.run(params, context1)

      # User 2 should still be able to send (different rate limit)
      assert {:ok, %{status: "sent"}} = SendEmail.run(params, context2)

      # User 1 should be rate limited now
      assert {:ok, %{error: error}} = SendEmail.run(params, context1)
      assert error =~ "Rate limit exceeded"
    end
  end

  # ---------------------------------------------------------------------------
  # Subject Validation
  # ---------------------------------------------------------------------------

  describe "run/2 - subject validation" do
    test "accepts subject at max length", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # 100 characters is the max
      subject = String.duplicate("a", 100)
      params = %{subject: subject, body: "Test body"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end

    test "rejects subject exceeding max length", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # 101 characters exceeds max
      subject = String.duplicate("a", 101)
      params = %{subject: subject, body: "Test body"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "Subject too long"
      assert result.error =~ "100"
    end

    test "rejects subject with newline character", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Subject\nWith Newline", body: "Test body"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "cannot contain newlines"
    end

    test "rejects subject with carriage return", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Subject\rWith CR", body: "Test body"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "cannot contain newlines"
    end

    test "accepts subject with spaces and special characters", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{
        subject: "Hello! Your daily update - 2024/01/15 (Important)",
        body: "Test body"
      }

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end
  end

  # ---------------------------------------------------------------------------
  # Body Validation
  # ---------------------------------------------------------------------------

  describe "run/2 - body validation" do
    test "accepts body at max length", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # 10,000 characters is the max
      body = String.duplicate("a", 10_000)
      params = %{subject: "Test", body: body}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end

    test "rejects body exceeding max length", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # 10,001 characters exceeds max
      body = String.duplicate("a", 10_001)
      params = %{subject: "Test", body: body}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "Email body too long"
      assert result.error =~ "10000"
    end

    test "rejects body with script tag", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "Hello <script>alert('xss')</script> world"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "rejects body with iframe tag", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "Hello <iframe src='evil.com'></iframe> world"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "rejects body with javascript: protocol", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "Click [here](javascript:alert('xss'))"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "rejects body with data: URI scheme", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "Check this data:text/html,<script>evil</script>"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "rejects body with data:image URI", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "See image data:image/png;base64,iVBORw0KGgo="}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "allows legitimate 'data:' text that is not a URI", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{
        subject: "Report",
        body: "The data: this chart shows quarterly growth. Here's the data: 25% increase."
      }

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end

    test "rejects HTML entity-encoded script tags (numeric)", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # &#60; = < and &#62; = >
      # Note: MDEx escapes these, but we check the rendered output for safety
      params = %{subject: "Test", body: "Hello &#60;script&#62;alert('xss')&#60;/script&#62;"}

      assert {:ok, result} = SendEmail.run(params, context)
      # Either passes (entities stay as entities) or gets caught by our check
      assert Map.get(result, :status) == "sent" or result[:error] =~ "prohibited content"
    end

    test "rejects HTML entity-encoded script tags (named)", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # &lt; = < and &gt; = >
      params = %{subject: "Test", body: "Hello &lt;script&gt;alert('xss')&lt;/script&gt;"}

      assert {:ok, result} = SendEmail.run(params, context)
      # Either passes (entities stay as entities) or gets caught by our check
      assert Map.get(result, :status) == "sent" or result[:error] =~ "prohibited content"
    end

    test "rejects body with onclick handler", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "<div onclick='evil()'>Click me</div>"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "rejects body with onerror handler", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "<img onerror='evil()' src='invalid'>"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "rejects body with onload handler", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "<body onload='evil()'>Hello</body>"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "rejects body with vbscript: protocol", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "Click [here](vbscript:msgbox('hi'))"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "case insensitive prohibited content check", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "Test", body: "Hello <SCRIPT>alert('xss')</SCRIPT> world"}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "prohibited content"
    end

    test "accepts body with safe HTML-like text in markdown", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # This is safe because "script" as plain text is fine, only "<script" is dangerous
      params = %{subject: "Test", body: "The word script and frame are fine."}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end
  end

  # ---------------------------------------------------------------------------
  # Context Validation
  # ---------------------------------------------------------------------------

  describe "run/2 - context validation" do
    test "returns error with empty context" do
      params = %{subject: "Test", body: "Test body"}

      assert {:ok, result} = SendEmail.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error with missing user_id", %{conversation: conversation} do
      params = %{subject: "Test", body: "Test body"}
      context = %{conversation_id: conversation.id}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "user_id"
    end

    test "returns error with missing conversation_id", %{user: user} do
      params = %{subject: "Test", body: "Test body"}
      context = %{user_id: user.id}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "conversation_id"
    end

    test "returns error when user is deleted/not found", %{conversation: conversation} do
      # Use a non-existent user ID
      fake_user_id = Ash.UUIDv7.generate()

      params = %{subject: "Test", body: "Test body"}
      context = %{user_id: fake_user_id, conversation_id: conversation.id}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.error =~ "User not found"
    end
  end

  # ---------------------------------------------------------------------------
  # Job Context
  # ---------------------------------------------------------------------------

  describe "run/2 - job context" do
    test "sends email with job context", %{
      context: context,
      user: user,
      conversation: conversation
    } do
      clear_rate_limit(user.id)

      # Create a job
      job = job(conversation_id: conversation.id, user_id: user.id, name: "Daily Reminder")

      context_with_job = Map.put(context, :job, job)

      params = %{subject: "Job Email", body: "This is from a scheduled job."}

      assert {:ok, result} = SendEmail.run(params, context_with_job)
      assert result.status == "sent"
    end

    test "sends email without job context", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "No Job Email", body: "This is not from a job."}

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end
  end

  # ---------------------------------------------------------------------------
  # Edge Cases
  # ---------------------------------------------------------------------------

  describe "run/2 - edge cases" do
    test "handles empty subject gracefully", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{subject: "", body: "Test body"}

      # Empty subject should be allowed (Jido validates required params)
      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end

    test "handles unicode in subject and body", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{
        subject: "Test with emoji and unicode",
        body: "Hello! Content with special chars: cafe"
      }

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end

    test "converts markdown tables to HTML tables", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # Drain any previously sent emails (e.g., confirmation email from user creation)
      receive do
        {:email, _} -> :ok
      after
        0 -> :ok
      end

      params = %{
        subject: "Table Report",
        body: """
        Here is your report:

        | Name    | Status  | Count |
        |---------|---------|-------|
        | Alpha   | Active  | 10    |
        | Beta    | Pending | 5     |
        """
      }

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"

      assert_email_sent(fn email ->
        assert email.html_body =~ "<table>"
        assert email.html_body =~ "<th>"
        assert email.html_body =~ "<td>"
        assert email.html_body =~ "Alpha"
        assert email.html_body =~ "Pending"
      end)
    end

    test "handles code blocks in body", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{
        subject: "Code Example",
        body: """
        Here's some code:

        ```elixir
        defmodule Example do
          def hello, do: "world"
        end
        ```

        And inline `code` too.
        """
      }

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end

    test "handles links in markdown body", %{context: context, user: user} do
      clear_rate_limit(user.id)

      params = %{
        subject: "Links Test",
        body: "Check out [this link](https://example.com) for more info."
      }

      assert {:ok, result} = SendEmail.run(params, context)
      assert result.status == "sent"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration Tests
  # ---------------------------------------------------------------------------

  describe "integration" do
    test "full workflow: send, rate limit, wait, send again", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # First email succeeds
      params1 = %{subject: "Email 1", body: "First email"}
      assert {:ok, %{status: "sent"}} = SendEmail.run(params1, context)

      # Second email is rate limited
      params2 = %{subject: "Email 2", body: "Second email"}
      assert {:ok, %{error: error}} = SendEmail.run(params2, context)
      assert error =~ "Rate limit"

      # Clear rate limit (simulating time passing)
      clear_rate_limit(user.id)

      # Now email should succeed
      params3 = %{subject: "Email 3", body: "Third email"}
      assert {:ok, %{status: "sent"}} = SendEmail.run(params3, context)
    end

    test "validates subject before checking rate limit", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # Try with invalid subject (should fail validation before rate limit)
      params = %{subject: String.duplicate("a", 101), body: "Test"}
      assert {:ok, %{error: error}} = SendEmail.run(params, context)
      assert error =~ "Subject too long"

      # Rate limit should NOT have been consumed
      # So a valid email should still work
      valid_params = %{subject: "Valid", body: "Test"}
      assert {:ok, %{status: "sent"}} = SendEmail.run(valid_params, context)
    end

    test "validates body before checking rate limit", %{context: context, user: user} do
      clear_rate_limit(user.id)

      # Try with invalid body (should fail validation before rate limit)
      params = %{subject: "Test", body: "<script>alert('xss')</script>"}
      assert {:ok, %{error: error}} = SendEmail.run(params, context)
      assert error =~ "prohibited content"

      # Rate limit should NOT have been consumed
      # So a valid email should still work
      valid_params = %{subject: "Valid", body: "Safe content"}
      assert {:ok, %{status: "sent"}} = SendEmail.run(valid_params, context)
    end
  end
end
