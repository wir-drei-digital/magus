defmodule Magus.Brain.SourceIngesterTest do
  use Magus.DataCase, async: true

  alias Magus.Brain.SourceIngester

  describe "extract_title/1" do
    test "extracts title from content map" do
      assert SourceIngester.extract_title(%{"title" => "My Title"}) == "My Title"
      assert SourceIngester.extract_title(%{"text" => "Fallback"}) == "Fallback"
      assert SourceIngester.extract_title(%{}) == "Untitled Source"
      assert SourceIngester.extract_title(%{"title" => ""}) == "Untitled Source"
      assert SourceIngester.extract_title(nil) == "Untitled Source"
    end
  end
end
