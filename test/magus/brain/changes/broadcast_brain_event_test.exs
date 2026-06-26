defmodule Magus.Brain.Changes.BroadcastBrainEventTest do
  use Magus.DataCase, async: true
  import Magus.Generators
  alias Magus.Brain

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Broadcast Test"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "Page"}, actor: user)
    MagusWeb.Endpoint.subscribe("brain:#{brain.id}")
    MagusWeb.Endpoint.subscribe("brain:#{brain.id}:page:#{page.id}")
    %{user: user, brain: brain, page: page}
  end

  describe "page creation" do
    test "broadcasts page.created to brain-level topic with actor_id", %{
      user: user,
      brain: brain
    } do
      flush_messages()

      {:ok, new_page} = Brain.create_page(brain.id, %{title: "New Page"}, actor: user)

      brain_topic = "brain:#{brain.id}"

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^brain_topic,
                       event: "page.created",
                       payload: %{brain_id: brain_id, record: record, actor_id: actor_id}
                     },
                     2000

      assert brain_id == brain.id
      assert record.id == new_page.id
      assert actor_id == user.id
    end
  end

  describe "page body update" do
    test "broadcasts page.body_updated to both brain and page topics", %{
      user: user,
      brain: brain,
      page: page
    } do
      flush_messages()

      {:ok, _updated} =
        Brain.update_page_body(
          page,
          %{body: "new body", base_version: page.lock_version},
          actor: user
        )

      brain_topic = "brain:#{brain.id}"
      page_topic = "brain:#{brain.id}:page:#{page.id}"

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^brain_topic,
                       event: "page.body_updated",
                       payload: %{body: body, actor_id: actor_id}
                     },
                     2000

      assert body == "new body"
      assert actor_id == user.id

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^page_topic,
                       event: "page.body_updated",
                       payload: %{body: ^body}
                     },
                     2000
    end
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      50 -> :ok
    end
  end
end
