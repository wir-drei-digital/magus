defmodule MagusWeb.Rpc.ImageController do
  @moduledoc """
  Profile-image endpoints for the SvelteKit workbench (`POST /rpc/profile-image/*`).

  Handles the user avatar and custom-agent profile image via three actions:
  manual `upload` (multipart), AI `generate` (OpenRouterImage), and `remove`.
  Images are stored with `Magus.Files.Storage` under the public `avatars/` and
  `agent_images/` prefixes (served at `/uploads/files/`); the path is persisted
  on the User / CustomAgent through their policy-gated actions, so a caller can
  only touch their own avatar or an agent they own. Responses mirror the
  AshTypescript RPC envelope (`{success, data | errors}`).
  """
  use MagusWeb, :controller

  require Logger

  alias Magus.Agents.Providers.OpenRouterImage
  alias Magus.Files.Storage
  alias MagusWeb.Workbench.UploadHelpers

  @accepted_types ~w(image/jpeg image/png image/gif image/webp)

  # Style suffixes mirror MagusWeb.ProfileImageGeneratorComponent.
  @style_suffixes %{
    "none" => "",
    "photo" => ", photorealistic style, hyper-detailed, natural lighting, realistic textures",
    "flat" => ", flat illustration style, clean vector art, simple shapes, bold colors",
    "pixel" => ", pixel art style, retro 8-bit game aesthetic, crisp pixels",
    "threeD" => ", 3D rendered style, smooth lighting, soft shadows, clay-like material",
    "cartoon" => ", cartoon style, expressive, bold outlines, vibrant colors",
    "emoji" => ", emoji style, round expressive character, bold simple shapes, yellow skin tone",
    "minimal" => ", minimalist style, simple geometry, limited color palette, clean lines",
    "watercolor" => ", watercolor painting style, soft edges, blended colors, artistic texture"
  }

  # POST /rpc/profile-image/upload — multipart: file, kind, agent_id?
  def upload(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    user = conn.assigns.current_user

    with :ok <- check_size(upload),
         :ok <- check_type(upload),
         {:ok, target} <- resolve_target(params, user),
         {:ok, content} <- read_upload(upload),
         path = "#{target.prefix}/#{target.id}#{ext_for(upload)}",
         {:ok, _} <- Storage.store(path, content, content_type: upload.content_type),
         {:ok, url} <- persist(target, path, user) do
      json(conn, %{success: true, data: %{url: url, path: path}})
    else
      {:error, reason} -> json(conn, error_envelope(reason))
    end
  end

  def upload(conn, _params) do
    conn |> put_status(:bad_request) |> json(error_envelope("missing multipart \"file\" field"))
  end

  # POST /rpc/profile-image/generate — json: prompt, style, kind, agent_id?
  def generate(conn, %{"prompt" => prompt} = params) when is_binary(prompt) do
    user = conn.assigns.current_user

    case String.trim(prompt) do
      "" ->
        conn |> put_status(:bad_request) |> json(error_envelope("Please enter a prompt"))

      trimmed ->
        suffix = Map.get(@style_suffixes, params["style"] || "none", "")

        full_prompt =
          "Generate a profile picture/avatar: #{trimmed}#{suffix}. " <>
            "Square format, centered subject, clean background."

        # The default image model is resolved through the model-roles registry
        # (the `default_image?` flag was consolidated into the :image_default role).
        model_key = Magus.Models.Roles.resolve(:image_default)

        messages = [%{"role" => "user", "content" => full_prompt}]

        with {:ok, target} <- resolve_target(params, user),
             {:ok, data_url} <- generate_image(model_key, messages),
             {:ok, binary} <- decode_data_url(data_url),
             path = "#{target.prefix}/#{target.id}.png",
             {:ok, _} <- Storage.store(path, binary, content_type: "image/png"),
             {:ok, url} <- persist(target, path, user) do
          json(conn, %{success: true, data: %{url: url, path: path}})
        else
          {:error, reason} -> json(conn, error_envelope(reason))
        end
    end
  end

  def generate(conn, _params) do
    conn |> put_status(:bad_request) |> json(error_envelope("missing prompt"))
  end

  # POST /rpc/profile-image/remove — json: kind, agent_id?
  def remove(conn, params) do
    user = conn.assigns.current_user

    with {:ok, target} <- resolve_target(params, user),
         :ok <- clear(target, user) do
      json(conn, %{success: true, data: %{url: nil}})
    else
      {:error, reason} -> json(conn, error_envelope(reason))
    end
  end

  # ── Target: the user's avatar, or a custom agent the user owns ──────────────

  defp resolve_target(%{"kind" => "agent", "agent_id" => agent_id}, user) do
    case Ecto.UUID.cast(agent_id) do
      {:ok, id} ->
        case Magus.Agents.get_custom_agent(id, actor: user) do
          {:ok, agent} ->
            {:ok, %{kind: :agent, prefix: "agent_images", id: agent.id, agent: agent}}

          _ ->
            {:error, "agent not found"}
        end

      :error ->
        {:error, "invalid agent id"}
    end
  end

  defp resolve_target(_params, user) do
    {:ok, %{kind: :avatar, prefix: "avatars", id: user.id}}
  end

  # ── Persist the stored path on the resource, dropping the previous file ─────

  defp persist(%{kind: :avatar}, path, user) do
    if user.avatar_path && user.avatar_path != path, do: Storage.delete(user.avatar_path)

    case Magus.Accounts.update_avatar(user, path, actor: user) do
      {:ok, _updated} -> Storage.get_url(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist(%{kind: :agent, agent: agent}, path, user) do
    if agent.image_path && agent.image_path != path, do: Storage.delete(agent.image_path)

    case Magus.Agents.update_custom_agent(agent, %{image_path: path}, actor: user) do
      {:ok, _updated} -> Storage.get_url(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear(%{kind: :avatar}, user) do
    case Magus.Accounts.delete_avatar(user, actor: user) do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear(%{kind: :agent, agent: agent}, user) do
    if agent.image_path, do: Storage.delete(agent.image_path)

    case Magus.Agents.update_custom_agent(agent, %{image_path: nil}, actor: user) do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Image generation + data-url decoding ────────────────────────────────────

  defp generate_image(model_key, messages) do
    case OpenRouterImage.generate_image(model_key, messages,
           image_config: %{"aspect_ratio" => "1:1", "image_size" => "1K"}
         ) do
      {:ok, %{images: [%{"data_url" => data_url} | _]}} when is_binary(data_url) ->
        {:ok, data_url}

      {:ok, _} ->
        {:error, "The model did not return an image"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_data_url("data:" <> rest) do
    with [_meta, b64] <- String.split(rest, ",", parts: 2),
         {:ok, binary} <- Base.decode64(b64) do
      {:ok, binary}
    else
      _ -> {:error, "could not decode the generated image"}
    end
  end

  defp decode_data_url(_), do: {:error, "unexpected image format"}

  # ── Upload helpers (mirror UploadController) ────────────────────────────────

  defp ext_for(%Plug.Upload{content_type: content_type, filename: filename}) do
    case content_type do
      "image/png" -> ".png"
      "image/jpeg" -> ".jpg"
      "image/gif" -> ".gif"
      "image/webp" -> ".webp"
      _ -> filename |> to_string() |> Path.extname() |> String.downcase()
    end
  end

  defp check_type(%Plug.Upload{content_type: content_type}) do
    if content_type in @accepted_types do
      :ok
    else
      {:error, "unsupported image type (use JPEG, PNG, GIF, or WebP)"}
    end
  end

  defp check_size(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        if size <= UploadHelpers.max_file_size() do
          :ok
        else
          {:error, "file too large (max #{UploadHelpers.max_file_size()} bytes)"}
        end

      {:error, posix} ->
        {:error, "could not read upload: #{posix}"}
    end
  end

  defp read_upload(%Plug.Upload{path: path}) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, posix} -> {:error, "could not read upload: #{posix}"}
    end
  end

  defp error_envelope(reason) do
    message =
      case reason do
        reason when is_binary(reason) ->
          reason

        %Ash.Error.Invalid{errors: [first | _]} when is_exception(first) ->
          Exception.message(first)

        other ->
          Logger.warning("RPC profile-image failed: #{inspect(other)}")
          "Image operation failed"
      end

    %{
      success: false,
      errors: [
        %{
          type: "image_failed",
          message: message,
          shortMessage: "Image operation failed",
          vars: %{},
          fields: [],
          path: []
        }
      ]
    }
  end
end
