defmodule MagusWeb.ChatLive.Components.Brain.Blocks.FileBlockComponentTest do
  use MagusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias MagusWeb.ChatLive.Components.Brain.Blocks.FileBlockComponent

  test "renders inline image when file is image type" do
    block = %{content: %{"file_id" => "abc", "caption" => ""}, metadata: %{}}

    file = %{
      id: "abc",
      name: "pic.png",
      mime_type: "image/png",
      type: :image,
      file_size: 1024,
      file_path: "tmp/pic.png",
      status: :ready
    }

    html = render_component(&FileBlockComponent.file_block/1, block: block, file: file)

    assert html =~ "<img"
    assert html =~ "pic.png"
  end

  test "renders compact card for non-image" do
    block = %{content: %{"file_id" => "abc", "caption" => "Q3 plan"}, metadata: %{}}

    file = %{
      id: "abc",
      name: "doc.pdf",
      mime_type: "application/pdf",
      type: :document,
      file_size: 184_320,
      file_path: "tmp/doc.pdf",
      status: :ready
    }

    html = render_component(&FileBlockComponent.file_block/1, block: block, file: file)

    assert html =~ "doc.pdf"
    assert html =~ "Q3 plan"
    assert html =~ "180.0 KB"
    refute html =~ "<img"
  end

  test "renders placeholder when file is nil (deleted)" do
    block = %{content: %{"file_id" => "abc", "caption" => "vanished"}, metadata: %{}}
    html = render_component(&FileBlockComponent.file_block/1, block: block, file: nil)
    assert html =~ "no longer available"
    assert html =~ "vanished"
  end

  test "renders processing state when file status is :pending" do
    block = %{content: %{"file_id" => "abc", "caption" => ""}, metadata: %{}}

    file = %{
      id: "abc",
      name: "doc.pdf",
      mime_type: "application/pdf",
      type: :document,
      file_size: 1024,
      file_path: "tmp/doc.pdf",
      status: :pending
    }

    html = render_component(&FileBlockComponent.file_block/1, block: block, file: file)
    assert html =~ "Processing"
  end
end
