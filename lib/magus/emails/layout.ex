defmodule Magus.Emails.Layout do
  @moduledoc """
  Shared, inline-styled HTML layout and matching plain-text layout for all
  transactional emails sent by `Magus.Mail`.

  Email bodies are rendered in-repo (not via a provider template API) so any
  Swoosh adapter (Local in dev, Test in test, Postmark or SMTP in prod)
  delivers the same mail.

  Callers pass a content map and receive the rendered HTML or text string:

      content = %{
        preview: "...",          # short preheader text (HTML only)
        heading: "...",          # large heading at the top of the card
        greeting: "Hi Alice,",   # first line of the body
        paragraphs: ["...", ...],# body paragraphs (plain strings)
        cta: %{label: "Sign in", url: "https://..."}, # optional call to action
        footer_note: "..."       # optional small note above the footer links
      }

  All caller-supplied values are HTML-escaped before interpolation so user
  content (names, support topics, messages) cannot inject markup.
  """

  # Brand palette and typography, kept simple and email-client safe.
  @brand_color "#4f46e5"
  @text_color "#1f2937"
  @muted_color "#6b7280"
  @background "#f3f4f6"
  @card_background "#ffffff"
  @font "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"

  @doc """
  Renders the full HTML email for the given content map and footer data.

  `footer` is a map with `:product_name`, `:year`, `:support_url`, and
  `:discord_url`.
  """
  def render_html(content, footer) do
    preview = escape(content[:preview] || "")
    heading = escape(content.heading)
    greeting = escape(content.greeting)
    paragraphs_html = Enum.map_join(content.paragraphs, "\n", &paragraph_html/1)
    cta_html = cta_html(content[:cta])
    footer_note_html = footer_note_html(content[:footer_note])

    """
    <!DOCTYPE html>
    <html lang="en" xmlns="http://www.w3.org/1999/xhtml">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <meta http-equiv="X-UA-Compatible" content="IE=edge" />
      <title>#{heading}</title>
    </head>
    <body style="margin: 0; padding: 0; background-color: #{@background}; font-family: #{@font};">
      <div style="display: none; max-height: 0; overflow: hidden; opacity: 0;">#{preview}</div>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #{@background}; padding: 24px 0;">
        <tr>
          <td align="center">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width: 560px; width: 100%;">
              <tr>
                <td style="padding: 0 16px 16px; text-align: center;">
                  <span style="font-size: 22px; font-weight: 700; color: #{@brand_color}; letter-spacing: 0.5px;">Magus</span>
                </td>
              </tr>
              <tr>
                <td style="background-color: #{@card_background}; border-radius: 12px; padding: 32px; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08);">
                  <h1 style="margin: 0 0 16px; font-size: 20px; line-height: 1.3; color: #{@text_color};">#{heading}</h1>
                  <p style="margin: 0 0 16px; font-size: 15px; line-height: 1.6; color: #{@text_color};">#{greeting}</p>
                  #{paragraphs_html}
                  #{cta_html}
                  #{footer_note_html}
                </td>
              </tr>
              <tr>
                <td style="padding: 24px 16px; text-align: center; font-size: 12px; line-height: 1.6; color: #{@muted_color};">
                  #{footer_html(footer)}
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """
  end

  @doc """
  Renders the full plain-text email for the given content map and footer data.

  Mirrors the HTML version: greeting, body paragraphs, and the CTA URL as a
  raw link where applicable.
  """
  def render_text(content, footer) do
    sections =
      [
        content.heading,
        "",
        content.greeting,
        ""
      ] ++
        Enum.intersperse(content.paragraphs, "") ++
        cta_text(content[:cta]) ++
        footer_note_text(content[:footer_note]) ++
        [
          "",
          "--",
          footer_text(footer)
        ]

    sections
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # ---------------------------------------------------------------------------
  # HTML fragments
  # ---------------------------------------------------------------------------

  defp paragraph_html(paragraph) do
    ~s(<p style="margin: 0 0 16px; font-size: 15px; line-height: 1.6; color: #{@text_color};">#{escape(paragraph)}</p>)
  end

  defp cta_html(nil), do: ""

  defp cta_html(%{label: label, url: url}) do
    safe_label = escape(label)
    safe_url = escape(url)

    """
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin: 8px 0 24px;">
      <tr>
        <td style="border-radius: 8px; background-color: #{@brand_color};">
          <a href="#{safe_url}" target="_blank" rel="noopener" style="display: inline-block; padding: 12px 28px; font-size: 15px; font-weight: 600; color: #ffffff; text-decoration: none; border-radius: 8px;">#{safe_label}</a>
        </td>
      </tr>
    </table>
    <p style="margin: 0 0 8px; font-size: 13px; line-height: 1.6; color: #{@muted_color};">If the button does not work, copy and paste this link into your browser:</p>
    <p style="margin: 0 0 8px; font-size: 13px; line-height: 1.6; word-break: break-all;"><a href="#{safe_url}" target="_blank" rel="noopener" style="color: #{@brand_color};">#{safe_url}</a></p>
    """
  end

  defp footer_note_html(nil), do: ""

  defp footer_note_html(note) do
    ~s(<p style="margin: 16px 0 0; font-size: 13px; line-height: 1.6; color: #{@muted_color};">#{escape(note)}</p>)
  end

  defp footer_html(footer) do
    support_url = escape(footer.support_url)
    discord_url = escape(footer.discord_url)
    product_name = escape(footer.product_name)

    """
    <p style="margin: 0 0 8px;">
      <a href="#{support_url}" style="color: #{@muted_color}; text-decoration: underline;">Help &amp; support</a>
      &nbsp;&bull;&nbsp;
      <a href="#{discord_url}" style="color: #{@muted_color}; text-decoration: underline;">Discord community</a>
    </p>
    <p style="margin: 0;">&copy; #{footer.year} #{product_name}</p>
    """
  end

  # ---------------------------------------------------------------------------
  # Text fragments
  # ---------------------------------------------------------------------------

  defp cta_text(nil), do: []

  defp cta_text(%{label: label, url: url}) do
    ["", "#{label}: #{url}"]
  end

  defp footer_note_text(nil), do: []
  defp footer_note_text(note), do: ["", note]

  defp footer_text(footer) do
    """
    #{footer.product_name}
    Help & support: #{footer.support_url}
    Discord: #{footer.discord_url}
    (c) #{footer.year} #{footer.product_name}
    """
    |> String.trim_trailing()
  end

  # ---------------------------------------------------------------------------
  # Escaping
  # ---------------------------------------------------------------------------

  # HTML-escape any caller-supplied value (handles strings and other terms).
  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
