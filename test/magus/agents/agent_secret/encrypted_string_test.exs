defmodule Magus.Agents.AgentSecret.EncryptedStringTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.AgentSecret.EncryptedString

  describe "round-trip encryption" do
    test "encrypts and decrypts a string value" do
      {:ok, casted} = EncryptedString.cast_input("my-secret-value", [])
      assert casted == "my-secret-value"

      {:ok, stored} = EncryptedString.dump_to_native(casted, [])
      assert is_binary(stored)
      refute stored == "my-secret-value"

      {:ok, restored} = EncryptedString.cast_stored(stored, [])
      assert restored == "my-secret-value"
    end

    test "handles nil" do
      assert {:ok, nil} = EncryptedString.cast_input(nil, [])
    end

    test "cast_input rejects non-binary values" do
      assert :error = EncryptedString.cast_input(123, [])
      assert :error = EncryptedString.cast_input(%{key: "val"}, [])
    end

    test "cast_stored returns nil for nil" do
      assert {:ok, nil} = EncryptedString.cast_stored(nil, [])
    end

    test "dump_to_native returns nil for nil" do
      assert {:ok, nil} = EncryptedString.dump_to_native(nil, [])
    end

    test "stored ciphertext differs between encryptions" do
      {:ok, stored1} = EncryptedString.dump_to_native("same-value", [])
      {:ok, stored2} = EncryptedString.dump_to_native("same-value", [])

      # AES-GCM uses random IV so ciphertexts should differ
      refute stored1 == stored2

      # Both should decrypt to the same plaintext
      {:ok, restored1} = EncryptedString.cast_stored(stored1, [])
      {:ok, restored2} = EncryptedString.cast_stored(stored2, [])
      assert restored1 == restored2
    end
  end
end
