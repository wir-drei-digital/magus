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

  describe "resolve_backend/1 (magus-i5k6)" do
    # Pure env -> backend derivation used by config/runtime.exs at prod boot.
    # An env getter is injected so these touch no global state.
    test "explicit STORAGE_BACKEND=local wins even when AWS_BUCKET is set" do
      assert Storage.resolve_backend(env(%{"STORAGE_BACKEND" => "local", "AWS_BUCKET" => "b"})) ==
               :local
    end

    test "explicit STORAGE_BACKEND=s3 wins" do
      assert Storage.resolve_backend(env(%{"STORAGE_BACKEND" => "s3"})) == :s3
    end

    test "auto-selects :s3 when AWS_BUCKET is set and no explicit backend" do
      assert Storage.resolve_backend(env(%{"AWS_BUCKET" => "my-bucket"})) == :s3
    end

    test "auto-selects :local when nothing is configured" do
      assert Storage.resolve_backend(env(%{})) == :local
    end

    test "blank values fall through to :local (no silent s3)" do
      assert Storage.resolve_backend(env(%{"STORAGE_BACKEND" => "", "AWS_BUCKET" => ""})) ==
               :local
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

  # Builds an env getter over a fixed map, matching System.get_env/1's contract
  # (returns nil for absent keys).
  defp env(map), do: fn key -> Map.get(map, key) end
end
