defmodule Magus.EndpointTest do
  @moduledoc """
  Tests for `Magus.Endpoint`, the open-core / cloud endpoint facade.

  Core code routes `url/0`, `subscribe/2`, `unsubscribe/1`, and `broadcast/3`
  through this facade instead of naming `MagusWeb.Endpoint` directly, so
  `magus_cloud` can swap in its own endpoint via `:magus, :endpoint` config.
  """
  # async: false — the configurability test mutates the global :magus, :endpoint
  # app env, and the round-trip test uses refute_receive on PubSub.
  use ExUnit.Case, async: false

  # A stand-in endpoint that records delegation as tagged tuples, so we can
  # assert the facade forwards to whatever module is configured.
  defmodule FakeEndpoint do
    def url, do: "https://fake.example"
    def subscribe(topic, opts \\ []), do: {:fake, :subscribe, topic, opts}
    def unsubscribe(topic), do: {:fake, :unsubscribe, topic}
    def broadcast(topic, event, msg), do: {:fake, :broadcast, topic, event, msg}
  end

  describe "default configuration" do
    test "endpoint/0 defaults to MagusWeb.Endpoint" do
      assert Magus.Endpoint.endpoint() == MagusWeb.Endpoint
    end

    test "url/0 returns the real endpoint URL" do
      assert Magus.Endpoint.url() == MagusWeb.Endpoint.url()
    end
  end

  describe "PubSub round-trip via the default endpoint" do
    test "subscribe then broadcast delivers; unsubscribe stops delivery" do
      topic = "magus_endpoint_test:#{System.unique_integer([:positive])}"

      assert :ok = Magus.Endpoint.subscribe(topic)
      assert :ok = Magus.Endpoint.broadcast(topic, "ping", %{n: 1})
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "ping", payload: %{n: 1}}

      assert :ok = Magus.Endpoint.unsubscribe(topic)
      assert :ok = Magus.Endpoint.broadcast(topic, "ping", %{n: 2})
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "ping"}
    end
  end

  describe "configurable endpoint" do
    setup do
      original = Application.get_env(:magus, :endpoint)
      Application.put_env(:magus, :endpoint, FakeEndpoint)

      on_exit(fn ->
        if original do
          Application.put_env(:magus, :endpoint, original)
        else
          Application.delete_env(:magus, :endpoint)
        end
      end)
    end

    test "endpoint/0 reflects the configured module" do
      assert Magus.Endpoint.endpoint() == FakeEndpoint
    end

    test "url/0 delegates to the configured endpoint" do
      assert Magus.Endpoint.url() == "https://fake.example"
    end

    test "subscribe/2 delegates to the configured endpoint" do
      assert Magus.Endpoint.subscribe("t") == {:fake, :subscribe, "t", []}
      assert Magus.Endpoint.subscribe("t", a: 1) == {:fake, :subscribe, "t", [a: 1]}
    end

    test "unsubscribe/1 delegates to the configured endpoint" do
      assert Magus.Endpoint.unsubscribe("t") == {:fake, :unsubscribe, "t"}
    end

    test "broadcast/3 delegates to the configured endpoint" do
      assert Magus.Endpoint.broadcast("t", "evt", %{x: 1}) ==
               {:fake, :broadcast, "t", "evt", %{x: 1}}
    end
  end
end
