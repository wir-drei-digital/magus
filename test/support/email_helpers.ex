defmodule MagusWeb.EmailHelpers do
  @moduledoc """
  Helpers for extracting emails and tokens from Swoosh test adapter
  in browser-based E2E tests.
  """

  import ExUnit.Assertions

  @doc """
  Routes Swoosh emails to the test process in E2E tests.

  In Playwright tests the server runs in a different process, so emails sent
  by Swoosh.Adapters.Test are not delivered to the test process by default.
  Call this in your `setup` block to bridge that gap.

  ## Example

      setup do
        setup_email_delivery()
        :ok
      end
  """
  def setup_email_delivery do
    Application.put_env(:swoosh, :shared_test_process, self())

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:swoosh, :shared_test_process)
    end)
  end

  # Subjects matching Magus.Emails.Content. Emails are rendered in-repo now (not
  # via Postmark template IDs), so E2E helpers match on the subject line.
  @subjects %{
    magic_link: %{de: "Dein Anmeldelink für Magus", en: "Your Magus sign-in link"},
    mail_verification: %{
      de: "Bestätige deine E-Mail-Adresse",
      en: "Confirm your email address"
    },
    welcome: %{de: "Willkommen bei Magus", en: "Welcome to Magus"}
  }

  @doc """
  Collects all emails currently in the process mailbox.
  """
  def collect_emails do
    collect_emails([])
  end

  defp collect_emails(acc) do
    receive do
      {:email, email} -> collect_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  Drains all emails from the process mailbox, discarding them.
  Call this before the action you want to test to clear stale emails.
  """
  def drain_emails do
    receive do
      {:email, _} -> drain_emails()
    after
      0 -> :ok
    end
  end

  @doc """
  Finds an email matching the given template key (:magic_link, :mail_verification, :welcome)
  from the process mailbox. Waits up to `timeout_ms` for it to arrive.
  Returns `{:ok, email}` or `:error`.
  """
  def find_email(template_key, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout, 1_000)
    locale = Keyword.get(opts, :locale, :en)
    expected_subject = @subjects[template_key][locale]

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_find_email(expected_subject, deadline, [])
  end

  defp do_find_email(expected_subject, deadline, stash) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      # Put non-matching emails back
      for email <- Enum.reverse(stash), do: send(self(), {:email, email})
      :error
    else
      receive do
        {:email, email} ->
          if email.subject == expected_subject do
            # Put stashed emails back
            for e <- Enum.reverse(stash), do: send(self(), {:email, e})
            {:ok, email}
          else
            do_find_email(expected_subject, deadline, [email | stash])
          end
      after
        min(remaining, 50) ->
          do_find_email(expected_subject, deadline, stash)
      end
    end
  end

  @doc """
  Extracts the action URL (the CTA link) from a rendered email. The CTA URL is
  the first http(s) link in the text body, which precedes the footer links.
  """
  def extract_action_url(email) do
    body = email.text_body || email.html_body || ""

    case Regex.run(~r{https?://[^\s"<>]+}, body) do
      [url | _] -> url
      _ -> nil
    end
  end

  @doc """
  Extracts the token (last path segment) from an action URL.
  """
  def extract_token(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> String.split("/")
    |> List.last()
  end

  @doc """
  Extracts the path from an action URL (strips the host).
  """
  def extract_path(url) when is_binary(url) do
    URI.parse(url).path
  end

  @doc """
  Asserts that a welcome email was sent. Polls for up to 2 seconds
  since welcome emails are sent via Task.start (async).
  """
  def assert_welcome_email_sent(opts \\ []) do
    case find_email(:welcome, timeout: Keyword.get(opts, :timeout, 2_000)) do
      {:ok, email} -> email
      :error -> flunk("Expected welcome email to be sent, but none was found")
    end
  end

  @doc """
  Asserts that no welcome email is in the mailbox.
  Checks immediately (no waiting).
  """
  def assert_no_welcome_email do
    case find_email(:welcome, timeout: 200) do
      {:ok, _email} -> flunk("Expected no welcome email, but one was found")
      :error -> :ok
    end
  end
end
