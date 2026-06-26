defmodule Magus.Agents.Providers.OpenRouterVideoTest do
  use ExUnit.Case, async: false

  alias Magus.Agents.Providers.OpenRouterVideo

  describe "build_request_body/2" do
    test "text-to-video body includes set options only" do
      body =
        OpenRouterVideo.build_request_body("google/veo-3.1-fast",
          prompt: "a red bird flying",
          duration: 6,
          resolution: "1080p",
          aspect_ratio: "16:9",
          generate_audio: true
        )

      assert body["model"] == "google/veo-3.1-fast"
      assert body["prompt"] == "a red bird flying"
      assert body["duration"] == 6
      assert body["resolution"] == "1080p"
      assert body["aspect_ratio"] == "16:9"
      assert body["generate_audio"] == true
      refute Map.has_key?(body, "frame_images")
    end

    test "image-to-video adds frame_images with first_frame" do
      body =
        OpenRouterVideo.build_request_body("google/veo-3.1-fast",
          prompt: "animate this",
          image_url: "https://example.com/cat.png"
        )

      assert body["frame_images"] == [
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "https://example.com/cat.png"},
                 "frame_type" => "first_frame"
               }
             ]
    end

    test "omits keys that are nil" do
      body = OpenRouterVideo.build_request_body("google/veo-3.1-fast", prompt: "x")
      refute Map.has_key?(body, "duration")
      refute Map.has_key?(body, "resolution")
      refute Map.has_key?(body, "generate_audio")
    end
  end

  describe "chat/2 (stubbed HTTP)" do
    setup do
      System.put_env("OPENROUTER_API_KEY", "test-key")
      on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)
      :ok
    end

    test "submits, polls to completion, downloads bytes, returns usage.cost" do
      # Route all requests for this stub through one function that branches on path.
      Req.Test.stub(OpenRouterVideo, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/v1/videos"} ->
            Req.Test.json(conn, %{
              "id" => "vid_123",
              "polling_url" => "https://openrouter.ai/api/v1/videos/vid_123",
              "status" => "pending"
            })

          {"GET", "/api/v1/videos/vid_123"} ->
            Req.Test.json(conn, %{
              "id" => "vid_123",
              "status" => "completed",
              "unsigned_urls" => ["https://openrouter.ai/api/v1/videos/vid_123/content?index=0"],
              "usage" => %{"cost" => 0.25, "is_byok" => false}
            })

          {"GET", "/api/v1/videos/vid_123/content"} ->
            conn
            |> Plug.Conn.put_resp_content_type("video/mp4")
            |> Plug.Conn.send_resp(200, "FAKE-MP4-BYTES")
        end
      end)

      messages = [%{role: "user", content: "a red bird flying"}]

      assert {:ok, result} =
               Magus.Agents.Providers.OpenRouterVideo.chat(messages,
                 model: "google/veo-3.1-fast",
                 duration: 6
               )

      assert [%{"content" => "FAKE-MP4-BYTES", "mime_type" => "video/mp4"}] = result.videos
      assert Decimal.equal?(to_decimal(result.usage["cost"]), Decimal.from_float(0.25))
      assert result.duration == 6
    end

    test "keeps polling on a non-terminal status before completing" do
      # First poll returns "queued" (a status the old guard rejected); the
      # second poll returns "completed". chat/2 must continue past "queued".
      polls = start_supervised!({Agent, fn -> 0 end})

      Req.Test.stub(OpenRouterVideo, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/v1/videos"} ->
            Req.Test.json(conn, %{
              "id" => "vid_q",
              "polling_url" => "https://openrouter.ai/api/v1/videos/vid_q",
              "status" => "queued"
            })

          {"GET", "/api/v1/videos/vid_q"} ->
            n = Agent.get_and_update(polls, fn n -> {n, n + 1} end)

            if n == 0 do
              Req.Test.json(conn, %{"id" => "vid_q", "status" => "queued"})
            else
              Req.Test.json(conn, %{
                "id" => "vid_q",
                "status" => "completed",
                "unsigned_urls" => [
                  "https://openrouter.ai/api/v1/videos/vid_q/content?index=0"
                ],
                "usage" => %{"cost" => 0.5, "is_byok" => false}
              })
            end

          {"GET", "/api/v1/videos/vid_q/content"} ->
            conn
            |> Plug.Conn.put_resp_content_type("video/mp4")
            |> Plug.Conn.send_resp(200, "QUEUED-THEN-DONE")
        end
      end)

      messages = [%{role: "user", content: "a red bird flying"}]

      assert {:ok, result} =
               OpenRouterVideo.chat(messages, model: "google/veo-3.1-fast", duration: 8)

      assert [%{"content" => "QUEUED-THEN-DONE", "mime_type" => "video/mp4"}] = result.videos
      assert Decimal.equal?(to_decimal(result.usage["cost"]), Decimal.from_float(0.5))
      # Confirm we actually polled twice (queued -> completed).
      assert Agent.get(polls, & &1) == 2
    end

    test "returns an error when the poll reports a failed generation" do
      Req.Test.stub(OpenRouterVideo, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/v1/videos"} ->
            Req.Test.json(conn, %{
              "id" => "vid_fail",
              "polling_url" => "https://openrouter.ai/api/v1/videos/vid_fail",
              "status" => "pending"
            })

          {"GET", "/api/v1/videos/vid_fail"} ->
            Req.Test.json(conn, %{
              "id" => "vid_fail",
              "status" => "failed",
              "error" => "content policy violation"
            })
        end
      end)

      messages = [%{role: "user", content: "a red bird flying"}]

      assert {:error, {:generation_failed, "content policy violation"}} =
               OpenRouterVideo.chat(messages, model: "google/veo-3.1-fast")
    end

    defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
    defp to_decimal(%Decimal{} = d), do: d
  end
end
