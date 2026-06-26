defmodule Magus.Files.StorageTest do
  @moduledoc """
  Storage backend resolution and the `storage_backend` stamp (magus-rnh5).

  `async: false` because these tests mutate the global `:storage_backend`
  application config; ExUnit runs sync tests in isolation so the flip cannot
  leak into the async file tests that assume `:local`.
  """
  use Magus.ResourceCase, async: false

  alias Magus.Files.Storage

  setup do
    original = Application.get_env(:magus, :storage_backend)
    on_exit(fn -> Application.put_env(:magus, :storage_backend, original) end)
    :ok
  end

  describe "backend_name/0" do
    test "returns the configured backend as a string" do
      Application.put_env(:magus, :storage_backend, :s3)
      assert Storage.backend_name() == "s3"

      Application.put_env(:magus, :storage_backend, :local)
      assert Storage.backend_name() == "local"
    end
  end

  describe "create stamps the configured backend (magus-rnh5 regression)" do
    test "a file created under the :s3 backend records storage_backend \"s3\"" do
      # Before the fix this was hardcoded to "local", so prod (:s3) rows were
      # stamped "local" and deletes routed to the wrong backend, orphaning the
      # S3 object. Oban runs in :manual mode under test, so the :create action's
      # process_file trigger does not touch S3 here.
      Application.put_env(:magus, :storage_backend, :s3)

      user = generate(user())
      # create_for_user stamps the backend the same way (file.ex:332) but skips
      # the per-plan upload-limit validation that the actor path enforces.
      file = generate(file(user_id: user.id))

      assert file.storage_backend == "s3"
    end
  end
end
