defmodule Magus.Emails.Content do
  @moduledoc """
  Data-driven copy for every transactional email, in English and German.

  Each builder returns a map with a `:subject` and the `:content` map consumed
  by `Magus.Emails.Layout` (heading, greeting, paragraphs, optional cta and
  footer note). Locale is `:en` or `:de`.

  German copy uses informal address (du/dein, imperative like "klicke"/"gib"),
  never formal (Sie/Ihr).

  No em dashes are used anywhere in the copy.
  """

  @doc """
  Builds the subject and layout content for `email_key` in `locale` from
  `vars`.

  Returns `%{subject: String.t(), content: map()}`.
  """
  def build(email_key, locale, vars) do
    name = vars["name"] || ""

    case {email_key, locale} do
      {:magic_link, :en} ->
        %{
          subject: "Your Magus sign-in link",
          content: %{
            preview: "Use this link to sign in to Magus.",
            heading: "Sign in to Magus",
            greeting: greeting_en(name),
            paragraphs: [
              "Click the button below to sign in to your Magus account. This link will sign you in securely, no password needed.",
              "If you did not request this link, you can safely ignore this email."
            ],
            cta: %{label: "Sign in", url: vars["action_url"]}
          }
        }

      {:magic_link, :de} ->
        %{
          subject: "Dein Anmeldelink für Magus",
          content: %{
            preview: "Mit diesem Link meldest du dich bei Magus an.",
            heading: "Bei Magus anmelden",
            greeting: greeting_de(name),
            paragraphs: [
              "Klicke auf den Button unten, um dich bei deinem Magus Konto anzumelden. Dieser Link meldet dich sicher an, ganz ohne Passwort.",
              "Wenn du diesen Link nicht angefordert hast, kannst du diese E-Mail einfach ignorieren."
            ],
            cta: %{label: "Anmelden", url: vars["action_url"]}
          }
        }

      {:mail_verification, :en} ->
        %{
          subject: "Confirm your email address",
          content: %{
            preview: "Confirm your email to finish setting up Magus.",
            heading: "Confirm your email",
            greeting: greeting_en(name),
            paragraphs: [
              "Thanks for signing up for Magus. Please confirm your email address by clicking the button below.",
              "If you did not create a Magus account, you can safely ignore this email."
            ],
            cta: %{label: "Confirm your email", url: vars["action_url"]}
          }
        }

      {:mail_verification, :de} ->
        %{
          subject: "Bestätige deine E-Mail-Adresse",
          content: %{
            preview: "Bestätige deine E-Mail, um Magus einzurichten.",
            heading: "E-Mail bestätigen",
            greeting: greeting_de(name),
            paragraphs: [
              "Danke, dass du dich bei Magus registriert hast. Bitte bestätige deine E-Mail-Adresse, indem du auf den Button unten klickst.",
              "Wenn du kein Magus Konto erstellt hast, kannst du diese E-Mail einfach ignorieren."
            ],
            cta: %{label: "E-Mail bestätigen", url: vars["action_url"]}
          }
        }

      {:password_recovery, :en} ->
        %{
          subject: "Reset your Magus password",
          content: %{
            preview: "Reset the password for your Magus account.",
            heading: "Reset your password",
            greeting: greeting_en(name),
            paragraphs: [
              "We received a request to reset the password for your Magus account. Click the button below to choose a new password.",
              "If you did not request a password reset, you can safely ignore this email. Your password will stay the same."
            ],
            cta: %{label: "Reset password", url: vars["action_url"]}
          }
        }

      {:password_recovery, :de} ->
        %{
          subject: "Setze dein Magus Passwort zurück",
          content: %{
            preview: "Setze das Passwort für dein Magus Konto zurück.",
            heading: "Passwort zurücksetzen",
            greeting: greeting_de(name),
            paragraphs: [
              "Wir haben eine Anfrage erhalten, das Passwort für dein Magus Konto zurückzusetzen. Klicke auf den Button unten, um ein neues Passwort zu wählen.",
              "Wenn du kein neues Passwort angefordert hast, kannst du diese E-Mail einfach ignorieren. Dein Passwort bleibt unverändert."
            ],
            cta: %{label: "Passwort zurücksetzen", url: vars["action_url"]}
          }
        }

      {:welcome, :en} ->
        %{
          subject: "Welcome to Magus",
          content: %{
            preview: "Welcome aboard. Here is how to get started with Magus.",
            heading: "Welcome to Magus",
            greeting: greeting_en(name),
            paragraphs: [
              "Welcome to Magus. We are glad to have you here.",
              "Magus is your space for AI chat, a prompt library, and a knowledge brain that grows with you. Jump in whenever you are ready."
            ],
            cta: %{label: "Open Magus", url: vars["magus_url"]}
          }
        }

      {:welcome, :de} ->
        %{
          subject: "Willkommen bei Magus",
          content: %{
            preview: "Willkommen an Bord. So legst du mit Magus los.",
            heading: "Willkommen bei Magus",
            greeting: greeting_de(name),
            paragraphs: [
              "Willkommen bei Magus. Schön, dass du dabei bist.",
              "Magus ist dein Ort für KI-Chat, eine Prompt-Bibliothek und ein Wissensgehirn, das mit dir wächst. Leg einfach los, wann immer du bereit bist."
            ],
            cta: %{label: "Magus öffnen", url: vars["magus_url"]}
          }
        }

      {:downgrade, :en} ->
        %{
          subject: "Your Magus plan has changed",
          content: %{
            preview: "Your Magus plan has been downgraded.",
            heading: "Your plan has changed",
            greeting: greeting_en(name),
            paragraphs: [
              "Your Magus subscription has been downgraded. You can keep using Magus on your current plan.",
              "You can upgrade again at any time from your account settings to unlock more credits and features."
            ]
          }
        }

      {:downgrade, :de} ->
        %{
          subject: "Dein Magus Tarif hat sich geändert",
          content: %{
            preview: "Dein Magus Tarif wurde herabgestuft.",
            heading: "Dein Tarif hat sich geändert",
            greeting: greeting_de(name),
            paragraphs: [
              "Dein Magus Abo wurde herabgestuft. Du kannst Magus mit deinem aktuellen Tarif weiter nutzen.",
              "Du kannst jederzeit in deinen Kontoeinstellungen wieder upgraden, um mehr Credits und Funktionen freizuschalten."
            ]
          }
        }

      {:goodbye, :en} ->
        %{
          subject: "Your Magus account has been closed",
          content: %{
            preview: "Your Magus account has been closed.",
            heading: "Sorry to see you go",
            greeting: greeting_en(name),
            paragraphs: [
              "Your Magus account has been closed and your subscription has ended.",
              "We are sorry to see you go. If you change your mind, you are always welcome back. Just sign up again whenever you like."
            ]
          }
        }

      {:goodbye, :de} ->
        %{
          subject: "Dein Magus Konto wurde geschlossen",
          content: %{
            preview: "Dein Magus Konto wurde geschlossen.",
            heading: "Schade, dass du gehst",
            greeting: greeting_de(name),
            paragraphs: [
              "Dein Magus Konto wurde geschlossen und dein Abo ist beendet.",
              "Schade, dass du gehst. Falls du es dir anders überlegst, bist du jederzeit wieder willkommen. Registriere dich einfach erneut, wann immer du magst."
            ]
          }
        }

      {:upgraded, :en} ->
        %{
          subject: "Thanks for upgrading Magus",
          content: %{
            preview: "Your Magus upgrade is active.",
            heading: "Thanks for upgrading",
            greeting: greeting_en(name),
            paragraphs: [
              "Thanks for upgrading your Magus plan. Your new plan is now active.",
              "You now have access to more credits and features. Enjoy everything Magus has to offer."
            ]
          }
        }

      {:upgraded, :de} ->
        %{
          subject: "Danke für dein Upgrade bei Magus",
          content: %{
            preview: "Dein Magus Upgrade ist aktiv.",
            heading: "Danke für dein Upgrade",
            greeting: greeting_de(name),
            paragraphs: [
              "Danke, dass du deinen Magus Tarif aufgewertet hast. Dein neuer Tarif ist jetzt aktiv.",
              "Du hast nun Zugriff auf mehr Credits und Funktionen. Viel Freude mit allem, was Magus zu bieten hat."
            ]
          }
        }

      {:support_request, :en} ->
        topic = vars["topic"] || ""
        message = vars["message"] || ""

        %{
          subject: "We received your support request",
          content: %{
            preview: "We received your support request and will reply soon.",
            heading: "We received your request",
            greeting: greeting_en(name),
            paragraphs: [
              "Thanks for reaching out to Magus support. We received your request and will get back to you as soon as we can.",
              "Topic: #{topic}",
              "Your message:",
              message
            ],
            footer_note:
              "You do not need to reply to this email. We will respond to your request directly."
          }
        }

      {:support_request, :de} ->
        topic = vars["topic"] || ""
        message = vars["message"] || ""

        %{
          subject: "Wir haben deine Support-Anfrage erhalten",
          content: %{
            preview: "Wir haben deine Support-Anfrage erhalten und melden uns bald.",
            heading: "Wir haben deine Anfrage erhalten",
            greeting: greeting_de(name),
            paragraphs: [
              "Danke, dass du dich an den Magus Support gewendet hast. Wir haben deine Anfrage erhalten und melden uns so schnell wie möglich bei dir.",
              "Thema: #{topic}",
              "Deine Nachricht:",
              message
            ],
            footer_note:
              "Du musst auf diese E-Mail nicht antworten. Wir antworten direkt auf deine Anfrage."
          }
        }
    end
  end

  defp greeting_en(""), do: "Hi,"
  defp greeting_en(name), do: "Hi #{name},"

  defp greeting_de(""), do: "Hallo,"
  defp greeting_de(name), do: "Hallo #{name},"
end
