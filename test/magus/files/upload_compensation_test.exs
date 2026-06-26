defmodule Magus.Files.UploadCompensationTest do
  @moduledoc """
  Storage compensation when the DB record is rejected after the bytes are
  already written (magus-pnoh).
  """
  use Magus.ResourceCase, async: true

  alias Magus.Files.Upload
  alias Magus.Files.Storage.Local

  test "deletes orphaned bytes when create_file is rejected" do
    # A freshly generated user has no plan, so the :create action's storage-limit
    # validation rejects any non-empty upload. Storage.store has already written
    # the bytes by then, so they must be compensated rather than orphaned.
    user = generate(user())
    content = "orphan check"

    assert {:error, _} =
             Upload.create_file_from_upload(
               content,
               "x.txt",
               "text/plain",
               byte_size(content),
               actor: user
             )

    leftover = Path.wildcard(Path.join([File.cwd!(), Local.base_path(), user.id, "*"]))
    assert leftover == [], "expected no orphaned bytes, found: #{inspect(leftover)}"
  end
end
