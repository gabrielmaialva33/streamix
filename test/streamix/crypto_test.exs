defmodule Streamix.CryptoTest do
  use ExUnit.Case, async: true

  alias Streamix.Crypto

  describe "without encryption key (passthrough)" do
    setup do
      original = Application.get_env(:streamix, :provider_encryption_key)
      Application.put_env(:streamix, :provider_encryption_key, nil)
      on_exit(fn -> Application.put_env(:streamix, :provider_encryption_key, original) end)
      :ok
    end

    test "encrypt returns plaintext" do
      assert Crypto.encrypt("my_password") == "my_password"
    end

    test "decrypt returns plaintext" do
      assert Crypto.decrypt("my_password") == "my_password"
    end

    test "nil passthrough" do
      assert Crypto.encrypt(nil) == nil
      assert Crypto.decrypt(nil) == nil
    end

    test "empty string passthrough" do
      assert Crypto.encrypt("") == ""
      assert Crypto.decrypt("") == ""
    end
  end

  describe "with encryption key" do
    setup do
      original = Application.get_env(:streamix, :provider_encryption_key)
      # 32-byte key
      Application.put_env(:streamix, :provider_encryption_key, "01234567890123456789012345678901")
      on_exit(fn -> Application.put_env(:streamix, :provider_encryption_key, original) end)
      :ok
    end

    test "encrypt produces different output than plaintext" do
      encrypted = Crypto.encrypt("my_password")
      assert encrypted != "my_password"
      assert is_binary(encrypted)
    end

    test "encrypt/decrypt roundtrip" do
      plaintext = "super_secret_password_123!@#"
      encrypted = Crypto.encrypt(plaintext)
      assert Crypto.decrypt(encrypted) == plaintext
    end

    test "each encryption produces different ciphertext (random IV)" do
      plaintext = "same_password"
      a = Crypto.encrypt(plaintext)
      b = Crypto.encrypt(plaintext)
      assert a != b
      # But both decrypt to the same value
      assert Crypto.decrypt(a) == plaintext
      assert Crypto.decrypt(b) == plaintext
    end

    test "decrypt handles plaintext gracefully (backwards compat)" do
      # A value that was stored before encryption was enabled
      assert Crypto.decrypt("old_plaintext_password") == "old_plaintext_password"
    end

    test "nil roundtrip" do
      assert Crypto.encrypt(nil) == nil
      assert Crypto.decrypt(nil) == nil
    end

    test "empty string roundtrip" do
      assert Crypto.encrypt("") == ""
      assert Crypto.decrypt("") == ""
    end

    test "unicode roundtrip" do
      plaintext = "senha_com_açéntos_ñ_ü_日本語"
      encrypted = Crypto.encrypt(plaintext)
      assert Crypto.decrypt(encrypted) == plaintext
    end
  end

  describe "with short encryption key (auto-hashed to 32 bytes)" do
    setup do
      original = Application.get_env(:streamix, :provider_encryption_key)
      Application.put_env(:streamix, :provider_encryption_key, "short-key")
      on_exit(fn -> Application.put_env(:streamix, :provider_encryption_key, original) end)
      :ok
    end

    test "encrypt/decrypt roundtrip with short key" do
      plaintext = "test_password"
      encrypted = Crypto.encrypt(plaintext)
      assert encrypted != plaintext
      assert Crypto.decrypt(encrypted) == plaintext
    end
  end
end
