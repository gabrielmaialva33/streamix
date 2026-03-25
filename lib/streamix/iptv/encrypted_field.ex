defmodule Streamix.Iptv.EncryptedField do
  @moduledoc """
  Custom Ecto type that transparently encrypts/decrypts string fields.

  - On `dump` (write to DB): encrypts the plaintext value.
  - On `load` (read from DB): decrypts the ciphertext (or returns plaintext if not encrypted).
  """
  use Ecto.Type

  alias Streamix.Crypto

  @impl true
  def type, do: :string

  @impl true
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(nil), do: {:ok, nil}
  def cast(_), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(value) when is_binary(value), do: {:ok, Crypto.encrypt(value)}
  def dump(_), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(value) when is_binary(value), do: {:ok, Crypto.decrypt(value)}
  def load(_), do: :error

  @impl true
  def equal?(a, a), do: true
  def equal?(_, _), do: false
end
