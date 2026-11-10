defmodule Streamix.Library.Cipher do
  @moduledoc """
  Authenticated encryption and keyed hashing for the personal library.

  Everything here is standard and built on OTP's `:crypto`:

    * AES-256-GCM with a random 96-bit nonce per message. A sealed blob is
      `<<version, nonce::12 bytes, tag::16 bytes, ciphertext>>`. The
      additional authenticated data names what the blob is and whose it is,
      so a row copied to another user or another table fails to open.
    * HKDF-SHA256 (RFC 5869) to derive independent subkeys.
    * HMAC-SHA256 for blind indexes: equal content gives an equal digest for
      the same user, and the digest is meaningless without that user's key.
  """

  alias Streamix.Library.Key

  @version 1
  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32
  # Sealed maps are padded to a multiple of this, so the ciphertext length
  # does not give away the content type or how many digits an id has.
  @padding_block 256

  @doc "Encrypts `plaintext` under a 32-byte `key`, binding it to `aad`."
  @spec seal(binary(), binary(), binary()) :: binary()
  def seal(<<_::binary-size(@key_bytes)>> = key, aad, plaintext)
      when is_binary(aad) and is_binary(plaintext) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, versioned(aad), true)

    <<@version, nonce::binary, tag::binary, ciphertext::binary>>
  end

  @doc "Decrypts a blob produced by `seal/3`. Any tampering returns `:error`."
  @spec open(binary(), binary(), binary()) :: {:ok, binary()} | :error
  def open(
        <<_::binary-size(@key_bytes)>> = key,
        aad,
        <<@version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>
      )
      when is_binary(aad) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           ciphertext,
           versioned(aad),
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def open(_key, _aad, _blob), do: :error

  @doc "Seals a JSON-encodable map for `key`'s owner under `context`."
  @spec seal_map(Key.t(), String.t(), map()) :: binary()
  def seal_map(%Key{} = key, context, map) when is_map(map) do
    seal(key.encryption_key, row_aad(key, context), pad(Jason.encode!(map)))
  end

  @doc "Opens a blob written by `seal_map/3`."
  @spec open_map(Key.t(), String.t(), binary()) :: {:ok, map()} | :error
  def open_map(%Key{} = key, context, blob) when is_binary(blob) do
    with {:ok, json} <- open(key.encryption_key, row_aad(key, context), blob),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  @doc """
  Blind index for `value` in `namespace`: HMAC-SHA256 under the user's index
  key.
  """
  @spec digest(Key.t(), String.t(), term()) :: binary()
  def digest(%Key{index_key: index_key}, namespace, value) when is_binary(namespace) do
    :crypto.mac(:hmac, :sha256, index_key, namespace <> ":" <> to_string(value))
  end

  @doc "HKDF-SHA256 with an all-zero salt, returning a 32-byte key."
  @spec hkdf(binary(), binary()) :: binary()
  def hkdf(input_key, info) when is_binary(input_key) and is_binary(info) do
    pseudo_random_key = :crypto.mac(:hmac, :sha256, <<0::256>>, input_key)
    # One expansion block is exactly 32 bytes, the only length we need.
    :crypto.mac(:hmac, :sha256, pseudo_random_key, info <> <<1>>)
  end

  defp row_aad(%Key{user_id: user_id}, context), do: "#{context}:user:#{user_id}"

  # JSON allows trailing whitespace, so the padding needs no framing.
  defp pad(json) do
    padding = rem(@padding_block - rem(byte_size(json), @padding_block), @padding_block)
    json <> :binary.copy(" ", padding)
  end

  defp versioned(aad), do: "streamix/library/v#{@version}/" <> aad
end
