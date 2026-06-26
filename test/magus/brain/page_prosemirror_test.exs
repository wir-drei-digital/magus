defmodule Magus.Brain.PageProsemirrorTest do
  use Magus.ResourceCase, async: true
  alias Magus.Brain

  test "loads page body as ProseMirror JSON, frontmatter stripped" do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, page} =
      Brain.update_page_body(
        page,
        %{body: "---\nicon: 🧠\n---\n- [x] done", base_version: page.lock_version},
        actor: user
      )

    {:ok, loaded} = Brain.get_page(page.id, actor: user, load: [:prosemirror])
    assert %{"type" => "doc", "content" => content} = loaded.prosemirror
    assert Enum.any?(content, &(&1["type"] == "taskList"))
    refute Enum.any?(content, &(&1["type"] == "horizontalRule"))
  end

  test "saves ProseMirror JSON back as markdown via update_body, preserving frontmatter" do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, page} =
      Brain.update_page_body(
        page,
        %{body: "---\nicon: 🧠\n---\nold", base_version: page.lock_version},
        actor: user
      )

    json = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "taskList",
          "content" => [
            %{
              "type" => "taskItem",
              "attrs" => %{"checked" => false},
              "content" => [
                %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "new"}]}
              ]
            }
          ]
        }
      ]
    }

    {:ok, saved} =
      Brain.update_page_body_from_prosemirror(page, json, page.lock_version, actor: user)

    assert saved.body == "---\nicon: 🧠\n---\n- [ ] new"
  end
end
