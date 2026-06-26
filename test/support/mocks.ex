defmodule Magus.Test.Mocks do
  @moduledoc """
  Mox mock definitions for external services.

  ## Usage

  In your test file:

      defmodule MyTest do
        use Magus.ResourceCase, async: true

        import Mox

        setup :verify_on_exit!

        test "calls LLM" do
          expect(Magus.Test.Mocks.LLMMock, :chat, fn _model, _context, _opts ->
            {:ok, %{content: "Hello!"}}
          end)

          # Test code that uses the mock
        end
      end

  ## Configuration

  To use mocks in your application, configure them in config/test.exs:

      config :magus, :llm_client, Magus.Test.Mocks.LLMMock

  Then in your application code, use:

      @llm_client Application.compile_env(:magus, :llm_client, ReqLLM)
  """
end

# ---------------------------------------------------------------------------
# Mock Response Helpers
# ---------------------------------------------------------------------------

defmodule Magus.Test.MockResponses do
  @moduledoc """
  Helper functions to build common mock responses for tests.

  ## Examples

      expect(LLMMock, :chat, fn _, _, _ ->
        MockResponses.chat_response("Hello, world!")
      end)
  """

  @doc "Build a successful chat completion response"
  def chat_response(content, opts \\ []) do
    {:ok,
     %{
       choices: [
         %{
           message: %{
             role: "assistant",
             content: content
           },
           index: 0,
           finish_reason: Keyword.get(opts, :finish_reason, "stop")
         }
       ],
       usage: %{
         prompt_tokens: Keyword.get(opts, :input_tokens, 10),
         completion_tokens: Keyword.get(opts, :output_tokens, 20),
         total_tokens: Keyword.get(opts, :total_tokens, 30)
       },
       model: Keyword.get(opts, :model, "test-model")
     }}
  end

  @doc "Build a streaming response with chunks"
  def streaming_response(text, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 5)

    chunks =
      text
      |> String.graphemes()
      |> Enum.chunk_every(chunk_size)
      |> Enum.map(&Enum.join/1)
      |> Enum.with_index()
      |> Enum.map(fn {chunk_text, index} ->
        %{
          type: :content,
          text: chunk_text,
          index: index
        }
      end)

    {:ok,
     %{
       stream: Stream.concat([chunks]),
       usage: %{
         input_tokens: Keyword.get(opts, :input_tokens, 10),
         output_tokens: String.length(text)
       }
     }}
  end

  @doc "Build a chat response with tool calls"
  def tool_call_response(tool_name, arguments, opts \\ []) do
    {:ok,
     %{
       choices: [
         %{
           message: %{
             role: "assistant",
             content: Keyword.get(opts, :content),
             tool_calls: [
               %{
                 id: Keyword.get(opts, :tool_id, "call_#{System.unique_integer([:positive])}"),
                 type: "function",
                 function: %{
                   name: tool_name,
                   arguments: Jason.encode!(arguments)
                 }
               }
             ]
           },
           finish_reason: "tool_calls"
         }
       ],
       usage: %{
         prompt_tokens: Keyword.get(opts, :input_tokens, 10),
         completion_tokens: Keyword.get(opts, :output_tokens, 20),
         total_tokens: 30
       }
     }}
  end

  @doc "Build an image generation response"
  def image_response(url, opts \\ []) do
    {:ok,
     %{
       data: [
         %{
           url: url,
           revised_prompt: Keyword.get(opts, :revised_prompt),
           b64_json: Keyword.get(opts, :b64_json)
         }
       ],
       created: DateTime.utc_now() |> DateTime.to_unix()
     }}
  end

  @doc "Build a video generation response"
  def video_response(video_url, opts \\ []) do
    {:ok,
     %{
       status: Keyword.get(opts, :status, "completed"),
       video_url: video_url,
       thumbnail_url: Keyword.get(opts, :thumbnail_url),
       duration: Keyword.get(opts, :duration, 5.0)
     }}
  end

  @doc "Build a video generation pending response"
  def video_pending_response(generation_id) do
    {:ok,
     %{
       status: "processing",
       generation_id: generation_id,
       progress: 50
     }}
  end

  @doc """
  Build a mock video generation chat response for VideoGenMock.

  Returns the format expected by GenerateVideo action:
  `{:ok, %{text: String.t(), videos: [map()], images: [], ...}}`

  ## Options

    * `:text` - Optional text response (default: "")
    * `:duration` - Video duration in seconds (default: 5.0)
    * `:use_content` - If true, provide binary content instead of URL (default: false)

  ## Examples

      # With URL (requires network access)
      expect(Magus.Test.Mocks.VideoGenMock, :chat, fn _messages, _opts ->
        MockResponses.generate_video_response("https://example.com/video.mp4")
      end)

      # With binary content (no network required, good for testing)
      expect(Magus.Test.Mocks.VideoGenMock, :chat, fn _messages, _opts ->
        MockResponses.generate_video_response("fake-video-data", use_content: true)
      end)

  """
  def generate_video_response(video_data, opts \\ []) when is_binary(video_data) do
    text = Keyword.get(opts, :text, "")
    duration = Keyword.get(opts, :duration, 5.0)
    use_content = Keyword.get(opts, :use_content, false)

    video =
      if use_content do
        %{
          "type" => "video",
          "content" => video_data,
          "mime_type" => "video/mp4",
          "duration" => duration
        }
      else
        %{
          "type" => "video",
          "url" => video_data,
          "duration" => duration
        }
      end

    {:ok,
     %{
       text: text,
       videos: [video],
       images: [],
       reasoning_details: [],
       tool_calls: [],
       finish_reason: "stop",
       usage: %{credits_used: 1}
     }}
  end

  @doc """
  Build a mock non-streaming text generation response for LLMMock.

  Returns `{:ok, %ReqLLM.Response{}}` format expected by GenerateTitle.

  ## Options

    * `:input_tokens` - Number of input tokens (default: 10)
    * `:output_tokens` - Number of output tokens (default: text length)

  ## Example

      expect(Magus.Test.Mocks.LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("Sourdough Bread Recipe")
      end)

  """
  def generate_text_response(text, opts \\ []) do
    input_tokens = Keyword.get(opts, :input_tokens, 10)
    output_tokens = Keyword.get(opts, :output_tokens, String.length(text))

    # Create a proper ReqLLM.Response struct that works with ReqLLM.Response.text/1
    {:ok,
     %ReqLLM.Response{
       id: "mock-response-#{System.unique_integer([:positive])}",
       model: "mock-model",
       context: ReqLLM.Context.new(),
       message: %ReqLLM.Message{
         role: :assistant,
         content: [ReqLLM.Message.ContentPart.text(text)]
       },
       usage: %{input_tokens: input_tokens, output_tokens: output_tokens},
       finish_reason: :stop
     }}
  end

  @doc """
  Build a mock message-less text generation response for LLMMock.

  Returns `{:ok, %ReqLLM.Response{message: nil}}`, for which
  `ReqLLM.Response.text/1` returns `nil`. Mirrors what some providers send back
  for an empty/refused completion. Used to prove SummarizeWindow coalesces nil
  to "" instead of crashing the compaction pass.

  ## Example

      expect(Magus.Test.Mocks.LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_nil_response()
      end)

  """
  def generate_text_nil_response do
    {:ok,
     %ReqLLM.Response{
       id: "mock-response-#{System.unique_integer([:positive])}",
       model: "mock-model",
       context: ReqLLM.Context.new(),
       message: nil,
       usage: %{input_tokens: 10, output_tokens: 0},
       finish_reason: :stop
     }}
  end

  @doc """
  Build a mock structured object generation response for LLMMock.

  Returns `{:ok, %{object: map(), usage: map()}}` format expected by
  GeneratePromptFromConversation and ExtractMemoriesFromConversation.

  ## Options

    * `:input_tokens` - Number of input tokens (default: 10)
    * `:output_tokens` - Number of output tokens (default: 50)

  ## Examples

      # For GeneratePromptFromConversation
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "content" => "Explain concepts simply",
          "suggested_type" => "user",
          "suggested_name" => "Simple Explanations"
        })
      end)

      # For ExtractMemoriesFromConversation
      expect(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "operations" => [
            %{
              "action" => "create",
              "name" => "User Preferences",
              "summary" => "User prefers dark mode",
              "content" => %{"theme" => "dark"},
              "reason" => "User stated preference"
            }
          ]
        })
      end)

  """
  def generate_object_response(object, opts \\ []) when is_map(object) do
    input_tokens = Keyword.get(opts, :input_tokens, 10)
    output_tokens = Keyword.get(opts, :output_tokens, 50)

    {:ok,
     %{
       object: object,
       usage: %{input_tokens: input_tokens, output_tokens: output_tokens}
     }}
  end

  @doc "Build an error response"
  def error_response(message, opts \\ []) do
    {:error,
     %{
       error: %{
         message: message,
         type: Keyword.get(opts, :type, "api_error"),
         code: Keyword.get(opts, :code, "unknown")
       }
     }}
  end

  @doc """
  Build a mock StreamResponse for LLM streaming tests.

  Returns a tuple `{:ok, %ReqLLM.StreamResponse{}}` that can be used
  to mock `Magus.Agents.Clients.LLM.stream_text/3` in tests.

  ## Options

    * `:input_tokens` - Number of input tokens (default: 10)
    * `:output_tokens` - Number of output tokens (default: text length)

  ## Example

      expect(Magus.Test.Mocks.LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Hello from the AI!")
      end)

  """
  def stream_text_response(text, opts \\ []) do
    chunks = build_stream_chunks(text)
    input_tokens = Keyword.get(opts, :input_tokens, 10)
    output_tokens = Keyword.get(opts, :output_tokens, String.length(text))

    # Start a MetadataHandle GenServer that returns the mock metadata
    {:ok, metadata_handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{
          usage: %{input_tokens: input_tokens, output_tokens: output_tokens},
          finish_reason: :stop
        }
      end)

    # Build minimal mock model
    model = %{id: "mock-model", provider: "mock"}

    # Build mock context
    context = ReqLLM.Context.new()

    {:ok,
     %ReqLLM.StreamResponse{
       stream: Stream.concat([chunks]),
       metadata_handle: metadata_handle,
       cancel: fn -> :ok end,
       model: model,
       context: context
     }}
  end

  @doc """
  Build a mock stream text response with tool calls.

  Returns a StreamResponse that contains both text content and tool call chunks.

  ## Example

      expect(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_with_tool_call("Let me search that", "web_search", %{query: "test"})
      end)

  """
  def stream_text_with_tool_call(text, tool_name, tool_args, opts \\ []) do
    text_chunks = build_stream_chunks(text)

    tool_chunk =
      ReqLLM.StreamChunk.tool_call(tool_name, tool_args, %{
        id: Keyword.get(opts, :tool_id, "call_#{System.unique_integer([:positive])}"),
        index: 0
      })

    all_chunks = text_chunks ++ [tool_chunk]

    input_tokens = Keyword.get(opts, :input_tokens, 10)
    output_tokens = Keyword.get(opts, :output_tokens, String.length(text))

    {:ok, metadata_handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{
          usage: %{input_tokens: input_tokens, output_tokens: output_tokens},
          finish_reason: :tool_use
        }
      end)

    model = %{id: "mock-model", provider: "mock"}
    context = ReqLLM.Context.new()

    {:ok,
     %ReqLLM.StreamResponse{
       stream: Stream.concat([all_chunks]),
       metadata_handle: metadata_handle,
       cancel: fn -> :ok end,
       model: model,
       context: context
     }}
  end

  # Build list of StreamChunks from text, splitting into words
  defp build_stream_chunks(text) do
    text
    |> String.split(~r/(?<=\s)/, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&ReqLLM.StreamChunk.text/1)
  end

  @doc """
  Build a mock image generation response for ImageGenMock.

  Returns the format expected by GenerateImage action:
  `{:ok, %{text: String.t(), images: [map()], usage: map()}}`

  ## Options

    * `:text` - Optional text response (default: "")
    * `:input_tokens` - Number of input tokens (default: 10)

  ## Example

      expect(Magus.Test.Mocks.ImageGenMock, :generate_image, fn _model, _context, _opts ->
        MockResponses.generate_image_response("fake-image-data")
      end)

  """
  def generate_image_response(image_data, opts \\ []) when is_binary(image_data) do
    text = Keyword.get(opts, :text, "")
    input_tokens = Keyword.get(opts, :input_tokens, 10)
    mime_type = Keyword.get(opts, :mime_type, "image/png")

    # Build data URL format that OpenRouterImage returns
    data_url = "data:#{mime_type};base64,#{Base.encode64(image_data)}"

    {:ok,
     %{
       text: text,
       images: [%{"type" => "image", "data_url" => data_url}],
       usage: %{
         "prompt_tokens" => input_tokens,
         "completion_tokens" => 0,
         "total_tokens" => input_tokens
       }
     }}
  end

  @doc """
  Build a mock image generation response with multiple images.

  ## Example

      expect(ImageGenMock, :generate_image, fn _model, _context, _opts ->
        MockResponses.generate_multi_image_response(["image1", "image2"])
      end)

  """
  def generate_multi_image_response(image_data_list, opts \\ []) when is_list(image_data_list) do
    text = Keyword.get(opts, :text, "")
    input_tokens = Keyword.get(opts, :input_tokens, 10)
    mime_type = Keyword.get(opts, :mime_type, "image/png")

    images =
      Enum.map(image_data_list, fn data ->
        data_url = "data:#{mime_type};base64,#{Base.encode64(data)}"
        %{"type" => "image", "data_url" => data_url}
      end)

    {:ok,
     %{
       text: text,
       images: images,
       usage: %{
         "prompt_tokens" => input_tokens,
         "completion_tokens" => 0,
         "total_tokens" => input_tokens
       }
     }}
  end
end
