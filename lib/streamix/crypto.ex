defmodule Streamix.Crypto do
  @moduledoc """
  Simple AES-256-GCM encryption for sensitive fields.

  Uses `:crypto.crypto_one_time_aead/6` with a random 12-byte IV per encryption.
  Ciphertext stored as: base64(iv <> tag <> ciphertext).

  Key sourced from `Application.get_env(:streamix, :provider_encryption_key)`.
  When no key is configured, acts as passthrough (no encryption) for dev convenience.
  """

  require Logger

  @iv_bytes 12
  @tag_bytes 16
  @aad "streamix"

  @doc """
  Encrypts plaintext with AES-256-GCM.
  Returns base64-encoded string, or plaintext if no key configured.
  """
  @spec encrypt(String.t() | nil) :: String.t() | nil
  def encrypt(nil), do: nil
  def encrypt(""), do: ""

  def encrypt(plaintext) when is_binary(plaintext) do
    case get_key() do
      nil ->
        plaintext

      key ->
        iv = :crypto.strong_rand_bytes(@iv_bytes)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

        Base.encode64(iv <> tag <> ciphertext)
    end
  end

  @doc """
  Decrypts an AES-256-GCM ciphertext.
  Falls back to returning the value as-is if decryption fails (backwards compat with plaintext).
  """
  @spec decrypt(String.t() | nil) :: String.t() | nil
  def decrypt(nil), do: nil
  def decrypt(""), do: ""

  def decrypt(value) when is_binary(value) do
    case get_key() do
      nil ->
        value

      key ->
        try_decrypt(value, key)
    end
  end

  defp try_decrypt(value, key) do
    with {:ok, decoded} <- Base.decode64(value),
         <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> <-
           decoded,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext
    else
      # Backwards compat: legacy plaintext values predate AES-GCM rollout and
      # must still decrypt. We log so an unexpected miss (e.g. corrupted
      # ciphertext or wrong key) is visible instead of silently returning
      # garbage. The value itself is never logged.
      _ ->
        Logger.warning(
          "Streamix.Crypto.decrypt fell back to raw value (#{byte_size(value)} bytes). " <>
            "Likely legacy plaintext, but check PROVIDER_ENCRYPTION_KEY if unexpected."
        )

        value
    end
  end

  defp get_key do
    case Application.get_env(:streamix, :provider_encryption_key) do
      nil -> nil
      "" -> nil
      key when is_binary(key) and byte_size(key) >= 32 -> :binary.part(key, 0, 32)
      key when is_binary(key) -> :crypto.hash(:sha256, key)
    end
  end
end
