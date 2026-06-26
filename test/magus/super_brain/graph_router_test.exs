defmodule Magus.SuperBrain.GraphRouterTest do
  use ExUnit.Case, async: true
  alias Magus.SuperBrain.GraphRouter

  test "brain_page goes to per-brain graph" do
    assert GraphRouter.graph_for({:brain_page, "brain-uuid", "page-uuid"}, _actor = nil) ==
             {:ok, "brain:brain-uuid"}
  end

  test "routes a brain source to the brain's graph" do
    assert {:ok, "brain:abc"} =
             Magus.SuperBrain.GraphRouter.graph_for({:brain_source, "abc", "src-1"}, nil)
  end

  test "personal memory goes to user graph" do
    assert GraphRouter.graph_for({:memory, "user-uuid", :personal}, nil) ==
             {:ok, "memories:user:user-uuid"}
  end

  test "workspace memory goes to workspace graph" do
    assert GraphRouter.graph_for({:memory, "user-uuid", {:workspace, "ws-uuid"}}, nil) ==
             {:ok, "memories:workspace:ws-uuid"}
  end

  test "personal file goes to user graph" do
    assert GraphRouter.graph_for({:file, "user-uuid", :personal}, nil) ==
             {:ok, "files:user:user-uuid"}
  end

  test "workspace file goes to workspace graph" do
    assert GraphRouter.graph_for({:file, "user-uuid", {:workspace, "ws-uuid"}}, nil) ==
             {:ok, "files:workspace:ws-uuid"}
  end

  test "draft goes to user graph" do
    assert GraphRouter.graph_for({:draft, "user-uuid", :any}, nil) ==
             {:ok, "drafts:user:user-uuid"}
  end

  test "personal file chunk goes to user files graph" do
    assert GraphRouter.graph_for({:file_chunk, "user-uuid", :personal}, nil) ==
             {:ok, "files:user:user-uuid"}
  end

  test "workspace file chunk goes to workspace files graph" do
    assert GraphRouter.graph_for({:file_chunk, "user-uuid", {:workspace, "ws-uuid"}}, nil) ==
             {:ok, "files:workspace:ws-uuid"}
  end
end
