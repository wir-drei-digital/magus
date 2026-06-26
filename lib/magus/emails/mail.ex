defmodule Magus.Mail do
  @moduledoc """
  Centralized module for sending transactional emails.

  Email bodies are rendered in-repo (HTML + plain text) via a shared layout
  (`Magus.Emails.Layout`) and a data-driven copy registry
  (`Magus.Emails.Content`). The rendered bodies are set on the Swoosh email
  with `html_body/1` and `text_body/1`, so any Swoosh adapter (Local in dev,
  Test in test, Postmark or SMTP in prod) delivers the same mail. No
  provider-side template API is used.

  Locale is determined from the user's `language` attribute (`:de` or `:en`,
  defaults to `:en`).

  ## Usage

      # With a user struct
      Magus.Mail.send_magic_link(user, action_url)

      # With a plain email string (defaults to EN, empty name)
      Magus.Mail.send_magic_link("new@example.com", action_url)

      # Send to an override email (e.g., email change confirmation)
      Magus.Mail.send_mail_verification_to("new@example.com", user, action_url)
  """

  require Logger

  import Swoosh.Email

  alias Magus.Emails.Content
  alias Magus.Emails.Layout

  @product_url "https://magus.digital"
  @product_name "Magus"
  @from_email "support@magus.digital"
  @from_name "Magus"
  @discord_url "https://discord.gg/6EfPDhmWRb"
  @support_url "https://magus.digital/help"

  # ---------------------------------------------------------------------------
  # Shared footer data
  # ---------------------------------------------------------------------------

  # Footer data injected into every rendered email. Computed at runtime so the
  # year is always accurate.
  defp footer do
    %{
      product_name: @product_name,
      year: Date.utc_today().year,
      support_url: @support_url,
      discord_url: @discord_url
    }
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Sends a magic link email.

  Accepts a user struct or plain email string.
  """
  def send_magic_link(user_or_email, action_url) do
    {email, name, locale} = extract_recipient(user_or_email)

    deliver(email, :magic_link, locale, %{
      "name" => name,
      "action_url" => action_url
    })
  end

  @doc """
  Sends an email verification (new user confirmation) email.

  Accepts a user struct or plain email string.
  """
  def send_mail_verification(user_or_email, action_url) do
    {email, name, locale} = extract_recipient(user_or_email)

    deliver(email, :mail_verification, locale, %{
      "name" => name,
      "action_url" => action_url
    })
  end

  @doc """
  Sends an email verification to a specific email address.

  Uses the user's display name and locale but sends to `to_email` instead
  of the user's primary email. Used for email change confirmations.
  """
  def send_mail_verification_to(to_email, user, action_url) do
    {_primary_email, name, locale} = extract_recipient(user)

    # `to_email` may arrive as an Ash.CiString (the email-change action's
    # `new_email` argument is a `:ci_string`); Swoosh recipients must be plain
    # binaries, so coerce before delivery.
    deliver(to_string(to_email), :mail_verification, locale, %{
      "name" => name,
      "action_url" => action_url
    })
  end

  @doc """
  Sends a password recovery email.
  """
  def send_password_recovery(user, action_url) do
    {email, name, locale} = extract_recipient(user)

    deliver(email, :password_recovery, locale, %{
      "name" => name,
      "action_url" => action_url
    })
  end

  @doc """
  Sends a welcome email.
  """
  def send_welcome(user) do
    {email, name, locale} = extract_recipient(user)

    deliver(email, :welcome, locale, %{
      "name" => name,
      "magus_url" => @product_url
    })
  end

  @doc """
  Sends a downgrade notification email.
  """
  def send_downgrade(user) do
    {email, name, locale} = extract_recipient(user)
    deliver(email, :downgrade, locale, %{"name" => name})
  end

  @doc """
  Sends a goodbye email.
  """
  def send_goodbye(user) do
    {email, name, locale} = extract_recipient(user)
    deliver(email, :goodbye, locale, %{"name" => name})
  end

  @doc """
  Sends an upgraded notification email.
  """
  def send_upgraded(user) do
    {email, name, locale} = extract_recipient(user)
    deliver(email, :upgraded, locale, %{"name" => name})
  end

  @doc """
  Sends a support request confirmation email to the user and a notification
  email to the support team at `support@magus.digital`.

  Accepts a user struct or plain email string, plus a map of form data
  with `:name`, `:email`, `:topic`, and `:message` keys.

  Returns `{:ok, _}` when both emails succeed, or `{:error, reason}` if
  either delivery fails.
  """
  def send_support_request(user_or_email, form_data) do
    {email, name, locale} = extract_recipient(user_or_email)

    confirmation_result =
      deliver(email, :support_request, locale, %{
        "name" => name,
        "topic" => form_data[:topic] || "",
        "message" => form_data[:message] || "",
        "contact_email" => form_data[:email] || ""
      })

    notification_result = send_support_notification(form_data)

    case {confirmation_result, notification_result} do
      {{:ok, _}, _} -> confirmation_result
      {{:error, _} = error, _} -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp send_support_notification(form_data) do
    name = form_data[:name] || ""
    email = form_data[:email] || ""
    topic = form_data[:topic] || ""
    message = form_data[:message] || ""

    subject = "Support Request [#{topic}] from #{name}"

    body = """
    New support request received:

    Name: #{name}
    Email: #{email}
    Topic: #{topic}

    Message:
    #{message}
    """

    result =
      new()
      |> from({@from_name, @from_email})
      |> to({"Magus Support", @from_email})
      |> reply_to({name, email})
      |> subject(subject)
      |> text_body(body)
      |> Magus.Mailer.deliver()

    case result do
      {:ok, _} = success ->
        success

      {:error, reason} = error ->
        Logger.warning(
          "Failed to deliver support notification to #{@from_email}: #{inspect(reason)}"
        )

        error
    end
  end

  defp deliver(to_email, email_key, locale, vars) do
    resolved_locale = resolve_locale(locale)
    %{subject: subject, content: content} = Content.build(email_key, resolved_locale, vars)
    footer = footer()

    result =
      new()
      |> from({@from_name, @from_email})
      |> to({"", to_email})
      |> subject(subject)
      |> html_body(Layout.render_html(content, footer))
      |> text_body(Layout.render_text(content, footer))
      |> put_provider_option(:message_stream, "outbound")
      |> Magus.Mailer.deliver()

    case result do
      {:ok, _} = success ->
        success

      {:error, reason} = error ->
        Logger.warning("Failed to deliver #{email_key} email to #{to_email}: #{inspect(reason)}")

        error
    end
  end

  defp extract_recipient(user_or_email) do
    case user_or_email do
      %{email: email, display_name: name, language: lang} ->
        {to_string(email), name || "", lang}

      %{email: email, language: lang} ->
        {to_string(email), "", lang}

      %{email: email} ->
        {to_string(email), "", nil}

      email when is_binary(email) ->
        {email, "", nil}
    end
  end

  defp resolve_locale(locale) when locale in [:en, :de], do: locale
  defp resolve_locale(_), do: :en
end
