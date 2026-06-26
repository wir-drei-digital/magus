defmodule Magus.Error do
  @moduledoc """
  Structured error types for consistent error handling across the application.

  This module provides a standard way to create and handle errors with:
  - A type atom for pattern matching
  - A human-readable message
  - Additional context for debugging
  - A recoverable flag for retry decisions

  ## Usage

      case fetch_user(id) do
        {:ok, user} -> {:ok, user}
        :not_found -> {:error, Magus.Error.not_found(:user, id)}
      end

  ## Error Types

  - `:not_found` - Resource doesn't exist
  - `:validation` - Input validation failed
  - `:unauthorized` - Actor lacks permission
  - `:external` - External service error
  - `:timeout` - Operation timed out
  - `:rate_limited` - Rate limit exceeded
  - `:internal` - Unexpected internal error

  ## For LLM-Facing Tools

  Tools should convert errors to user-friendly responses:

      def run(params, context) do
        case do_work(params) do
          {:ok, result} -> {:ok, %{success: true, data: result}}
          {:error, %Magus.Error{} = err} -> {:ok, %{success: false, error: err.message}}
        end
      end
  """

  defexception [:type, :message, :context, :recoverable?, :original]

  @type error_type ::
          :not_found
          | :validation
          | :unauthorized
          | :external
          | :timeout
          | :rate_limited
          | :internal

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          context: map(),
          recoverable?: boolean(),
          original: term()
        }

  @impl true
  def message(%__MODULE__{message: msg}), do: msg

  # =============================================================================
  # Error Constructors
  # =============================================================================

  @doc """
  Creates a not_found error for a missing resource.

  ## Examples

      Magus.Error.not_found(:user, "abc-123")
      #=> %Magus.Error{type: :not_found, message: "user not found", ...}

      Magus.Error.not_found(:conversation, id, actor: user.id)
      #=> %Magus.Error{..., context: %{resource: :conversation, id: id, actor: user_id}}
  """
  @spec not_found(atom(), term(), keyword()) :: t()
  def not_found(resource, id, opts \\ []) do
    context =
      opts
      |> Keyword.take([:actor, :action])
      |> Map.new()
      |> Map.merge(%{resource: resource, id: id})

    %__MODULE__{
      type: :not_found,
      message: "#{resource} not found",
      context: context,
      recoverable?: false,
      original: nil
    }
  end

  @doc """
  Creates a validation error for invalid input.

  ## Examples

      Magus.Error.validation(:email, "must be a valid email address")
      #=> %Magus.Error{type: :validation, message: "must be a valid email address", ...}

      Magus.Error.validation(:content, "exceeds maximum length", max: 8000, actual: 10000)
      #=> %Magus.Error{..., context: %{field: :content, max: 8000, actual: 10000}}
  """
  @spec validation(atom(), String.t(), keyword()) :: t()
  def validation(field, message, opts \\ []) do
    context =
      opts
      |> Map.new()
      |> Map.put(:field, field)

    %__MODULE__{
      type: :validation,
      message: message,
      context: context,
      recoverable?: true,
      original: nil
    }
  end

  @doc """
  Creates an unauthorized error when an actor lacks permission.

  ## Examples

      Magus.Error.unauthorized(:delete, :conversation, actor: user.id)
  """
  @spec unauthorized(atom(), atom(), keyword()) :: t()
  def unauthorized(action, resource, opts \\ []) do
    context =
      opts
      |> Keyword.take([:actor])
      |> Map.new()
      |> Map.merge(%{action: action, resource: resource})

    %__MODULE__{
      type: :unauthorized,
      message: "not authorized to #{action} #{resource}",
      context: context,
      recoverable?: false,
      original: nil
    }
  end

  @doc """
  Creates an external error for failures in external services.

  ## Examples

      Magus.Error.external(:openai, :rate_limited)
      Magus.Error.external(:google_calendar, {:http_error, 500}, retry_after: 60)
  """
  @spec external(atom(), term(), keyword()) :: t()
  def external(service, reason, opts \\ []) do
    context =
      opts
      |> Keyword.take([:retry_after, :request_id])
      |> Map.new()
      |> Map.put(:service, service)

    %__MODULE__{
      type: :external,
      message: "#{service} error: #{format_reason(reason)}",
      context: context,
      recoverable?: Keyword.get(opts, :recoverable?, true),
      original: reason
    }
  end

  @doc """
  Creates a timeout error when an operation exceeds its time limit.

  ## Examples

      Magus.Error.timeout(:memory_context, 3000)
      Magus.Error.timeout(:llm_stream, 300_000, model: "gpt-4")
  """
  @spec timeout(atom(), pos_integer(), keyword()) :: t()
  def timeout(operation, duration_ms, opts \\ []) do
    context =
      opts
      |> Map.new()
      |> Map.merge(%{operation: operation, duration_ms: duration_ms})

    %__MODULE__{
      type: :timeout,
      message: "#{operation} timed out after #{duration_ms}ms",
      context: context,
      recoverable?: true,
      original: nil
    }
  end

  @doc """
  Creates a rate_limited error when a rate limit is exceeded.

  ## Examples

      Magus.Error.rate_limited(:send_email, retry_after: 900)
      Magus.Error.rate_limited(:api_call, limit: 100, window: :hour)
  """
  @spec rate_limited(atom(), keyword()) :: t()
  def rate_limited(operation, opts \\ []) do
    context =
      opts
      |> Keyword.take([:retry_after, :limit, :window])
      |> Map.new()
      |> Map.put(:operation, operation)

    retry_after = Keyword.get(opts, :retry_after)

    message =
      if retry_after do
        "#{operation} rate limited, retry after #{retry_after}s"
      else
        "#{operation} rate limited"
      end

    %__MODULE__{
      type: :rate_limited,
      message: message,
      context: context,
      recoverable?: true,
      original: nil
    }
  end

  @doc """
  Creates an internal error for unexpected failures.

  Use this sparingly - prefer more specific error types when possible.

  ## Examples

      Magus.Error.internal("unexpected state", state: current_state)
  """
  @spec internal(String.t(), keyword()) :: t()
  def internal(message, opts \\ []) do
    context =
      opts
      |> Keyword.drop([:original])
      |> Map.new()

    %__MODULE__{
      type: :internal,
      message: message,
      context: context,
      recoverable?: false,
      original: Keyword.get(opts, :original)
    }
  end

  @doc """
  Wraps an existing exception as an Magus.Error.

  ## Examples

      rescue
        e in RuntimeError -> {:error, Magus.Error.wrap(e, context: %{operation: :parse})}
  """
  @spec wrap(Exception.t(), keyword()) :: t()
  def wrap(exception, opts \\ []) do
    context =
      opts
      |> Keyword.take([:context])
      |> Keyword.get(:context, %{})

    %__MODULE__{
      type: Keyword.get(opts, :type, :internal),
      message: Exception.message(exception),
      context: context,
      recoverable?: Keyword.get(opts, :recoverable?, false),
      original: exception
    }
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  @doc """
  Checks if an error is recoverable (can be retried).
  """
  @spec recoverable?(t()) :: boolean()
  def recoverable?(%__MODULE__{recoverable?: r}), do: r

  @doc """
  Converts an error to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      type: error.type,
      message: error.message,
      recoverable: error.recoverable?
    }
  end

  @doc """
  Converts an error to a user-friendly string for display.
  """
  @spec to_user_message(t()) :: String.t()
  def to_user_message(%__MODULE__{type: :not_found, context: %{resource: r}}) do
    "The requested #{r} could not be found."
  end

  def to_user_message(%__MODULE__{type: :unauthorized}) do
    "You don't have permission to perform this action."
  end

  def to_user_message(%__MODULE__{type: :rate_limited, context: %{retry_after: seconds}})
      when is_integer(seconds) do
    "Please wait #{seconds} seconds before trying again."
  end

  def to_user_message(%__MODULE__{type: :rate_limited}) do
    "Too many requests. Please try again later."
  end

  def to_user_message(%__MODULE__{type: :timeout}) do
    "The operation took too long. Please try again."
  end

  def to_user_message(%__MODULE__{type: :external, context: %{service: service}}) do
    "There was a problem connecting to #{service}. Please try again."
  end

  def to_user_message(%__MODULE__{message: msg}) do
    msg
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason({type, detail}), do: "#{type}: #{format_reason(detail)}"
  defp format_reason(reason), do: inspect(reason)
end
