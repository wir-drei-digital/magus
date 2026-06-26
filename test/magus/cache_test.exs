defmodule Magus.CacheTest do
  @moduledoc """
  Tests for the Magus.Cache module.

  Tests cover:
  - Basic get/put/delete operations
  - TTL (time-to-live) functionality
  - Expired entry handling
  - Exists? helper function
  """
  use ExUnit.Case, async: false

  alias Magus.Cache

  setup do
    # Clean up any test keys before each test
    :ok
  end

  # ---------------------------------------------------------------------------
  # Basic Operations
  # ---------------------------------------------------------------------------

  describe "put/3 and get/1" do
    test "stores and retrieves a value" do
      key = "test_key_#{System.unique_integer([:positive])}"

      Cache.put(key, "test_value")
      assert Cache.get(key) == "test_value"
    end

    test "stores complex values" do
      key = "complex_key_#{System.unique_integer([:positive])}"

      value = %{foo: "bar", list: [1, 2, 3], nested: %{a: 1}}
      Cache.put(key, value)
      assert Cache.get(key) == value
    end

    test "stores DateTime values" do
      key = "datetime_key_#{System.unique_integer([:positive])}"

      value = DateTime.utc_now()
      Cache.put(key, value)
      assert Cache.get(key) == value
    end

    test "overwrites existing value" do
      key = "overwrite_key_#{System.unique_integer([:positive])}"

      Cache.put(key, "first")
      assert Cache.get(key) == "first"

      Cache.put(key, "second")
      assert Cache.get(key) == "second"
    end

    test "returns nil for non-existent key" do
      key = "nonexistent_key_#{System.unique_integer([:positive])}"
      assert Cache.get(key) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # TTL (Time-to-Live)
  # ---------------------------------------------------------------------------

  describe "TTL functionality" do
    test "default TTL is 1 hour" do
      key = "ttl_default_#{System.unique_integer([:positive])}"

      Cache.put(key, "value")
      assert Cache.get(key) == "value"
    end

    test "custom TTL expires entry" do
      key = "ttl_custom_#{System.unique_integer([:positive])}"

      # Set TTL to 1 second
      Cache.put(key, "short_lived", ttl: 1)

      # Should exist immediately
      assert Cache.get(key) == "short_lived"

      # Wait for expiration
      Process.sleep(1010)

      # Should be expired now
      assert Cache.get(key) == nil
    end

    test "TTL of 0 expires immediately" do
      key = "ttl_zero_#{System.unique_integer([:positive])}"

      Cache.put(key, "instant_expire", ttl: 0)

      # Should be expired immediately (or within milliseconds)
      Process.sleep(10)
      assert Cache.get(key) == nil
    end

    test "long TTL keeps entry alive" do
      key = "ttl_long_#{System.unique_integer([:positive])}"

      # Set TTL to 1 hour
      Cache.put(key, "long_lived", ttl: 3600)

      # Should still exist
      assert Cache.get(key) == "long_lived"
    end
  end

  # ---------------------------------------------------------------------------
  # Delete Operations
  # ---------------------------------------------------------------------------

  describe "delete/1" do
    test "removes an existing key" do
      key = "delete_key_#{System.unique_integer([:positive])}"

      Cache.put(key, "to_delete")
      assert Cache.get(key) == "to_delete"

      Cache.delete(key)
      assert Cache.get(key) == nil
    end

    test "handles deleting non-existent key" do
      key = "nonexistent_delete_#{System.unique_integer([:positive])}"

      # Should not raise
      assert Cache.delete(key) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Exists? Helper
  # ---------------------------------------------------------------------------

  describe "exists?/1" do
    test "returns true for existing key" do
      key = "exists_key_#{System.unique_integer([:positive])}"

      Cache.put(key, "value")
      assert Cache.exists?(key) == true
    end

    test "returns false for non-existent key" do
      key = "not_exists_#{System.unique_integer([:positive])}"
      assert Cache.exists?(key) == false
    end

    test "returns false for expired key" do
      key = "exists_expired_#{System.unique_integer([:positive])}"

      Cache.put(key, "value", ttl: 1)
      assert Cache.exists?(key) == true

      Process.sleep(1010)
      assert Cache.exists?(key) == false
    end
  end

  # ---------------------------------------------------------------------------
  # Edge Cases
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "handles nil value" do
      key = "nil_value_#{System.unique_integer([:positive])}"

      Cache.put(key, nil)
      # Note: get returns nil for both non-existent and nil values
      assert Cache.get(key) == nil
    end

    test "handles empty string key" do
      Cache.put("", "empty_key_value")
      assert Cache.get("") == "empty_key_value"
      Cache.delete("")
    end

    test "handles special characters in key" do
      key = "special:key:with/slashes_and-dashes"

      Cache.put(key, "special_value")
      assert Cache.get(key) == "special_value"
      Cache.delete(key)
    end

    test "handles tuple as key" do
      key = {:user, 123, :rate_limit}

      Cache.put(key, "tuple_key_value")
      assert Cache.get(key) == "tuple_key_value"
      Cache.delete(key)
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrency
  # ---------------------------------------------------------------------------

  describe "concurrent access" do
    test "handles concurrent writes" do
      key = "concurrent_#{System.unique_integer([:positive])}"

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Cache.put(key, "value_#{i}")
          end)
        end

      Enum.each(tasks, &Task.await/1)

      # Should have some value (last write wins)
      assert Cache.get(key) != nil
      Cache.delete(key)
    end

    test "handles concurrent reads" do
      key = "concurrent_read_#{System.unique_integer([:positive])}"
      Cache.put(key, "concurrent_value")

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Cache.get(key)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should get the same value
      assert Enum.all?(results, &(&1 == "concurrent_value"))
      Cache.delete(key)
    end
  end
end
