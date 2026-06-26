defmodule MagusWeb.Workbench.Detail.SubscriptionSectionTest do
  @moduledoc """
  The subscription settings section is resolved through a seam so the
  always-loaded workbench (`SettingsView`) never compile-references the
  Billing-coupled `MagusWeb.SettingsLive.SubscriptionLive`. A pure-OSS build
  with no impl configured falls back to a neutral `Default` that renders a
  "not available" placeholder and ignores events.
  """
  # async: false — reads/writes the global seam config key.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MagusWeb.Workbench.Detail.SubscriptionSection

  @config_key MagusWeb.Workbench.Detail.SubscriptionSection

  setup do
    original = Application.get_env(:magus, @config_key)

    on_exit(fn ->
      if original,
        do: Application.put_env(:magus, @config_key, original),
        else: Application.delete_env(:magus, @config_key)
    end)

    :ok
  end

  describe "OSS default (no impl configured)" do
    setup do
      Application.delete_env(:magus, @config_key)
      :ok
    end

    test "init_assigns/2 returns the socket unchanged" do
      socket = %Phoenix.LiveView.Socket{}
      assert {:ok, ^socket} = SubscriptionSection.init_assigns(socket, %{id: "user-1"})
    end

    test "render_section/1 renders a neutral 'not available' placeholder" do
      html = rendered_to_string(SubscriptionSection.render_section(%{}))

      assert html =~ "not available"
      # The billing-specific spending-controls form must NOT leak into OSS.
      refute html =~ "save_billing_preferences"
    end

    test "handle_event/3 is a no-op" do
      socket = %Phoenix.LiveView.Socket{}
      assert {:noreply, ^socket} = SubscriptionSection.handle_event("anything", %{}, socket)
    end
  end

  describe "with a billing-edition impl configured" do
    defmodule FakeImpl do
      @behaviour MagusWeb.Workbench.Detail.SubscriptionSection

      import Phoenix.Component

      @impl true
      def init_assigns(socket, _user), do: {:ok, assign(socket, :delegated_init, true)}

      @impl true
      def render_section(assigns), do: ~H"<div>FAKE SUBSCRIPTION SECTION</div>"

      @impl true
      def handle_event(_event, _params, socket),
        do: {:noreply, assign(socket, :delegated_event, true)}
    end

    setup do
      Application.put_env(:magus, @config_key, impl: FakeImpl)
      :ok
    end

    test "init_assigns/2 delegates to the configured impl" do
      assert {:ok, socket} =
               SubscriptionSection.init_assigns(%Phoenix.LiveView.Socket{}, %{id: "user-1"})

      assert socket.assigns.delegated_init == true
    end

    test "render_section/1 delegates to the configured impl" do
      html = rendered_to_string(SubscriptionSection.render_section(%{}))
      assert html =~ "FAKE SUBSCRIPTION SECTION"
    end

    test "handle_event/3 delegates to the configured impl" do
      assert {:noreply, socket} =
               SubscriptionSection.handle_event("x", %{}, %Phoenix.LiveView.Socket{})

      assert socket.assigns.delegated_event == true
    end
  end
end
