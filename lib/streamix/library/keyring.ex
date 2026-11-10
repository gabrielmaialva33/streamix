defmodule Streamix.Library.Keyring do
  @moduledoc """
  Creates, wraps and unwraps library root keys.

  The root key is wrapped twice, and neither wrap opens with anything the
  server keeps:

    * **Password wrap** (`library_keys`): AES-256-GCM under
      PBKDF2-HMAC-SHA256(password, per-user salt). Opened at login, the only
      moment the server sees the password.
    * **Session wrap** (`users_tokens.library_key`): AES-256-GCM under a key
      derived from a random 32-byte secret. The secret goes to the client (the
      encrypted session cookie, or the API bearer token) and is never stored.

  Losing the password without knowing the old one (an admin reset, for
  instance) makes the old root unrecoverable. That is the point: nobody but
  the user can open it. A key is only ever discarded on that explicit path
  (`forget/1`); a password that cannot open it is an error, never a reason to
  replace it.

  The key is derived from the bytes bcrypt verifies — the first 72 — so every
  password the login accepts opens it.
  """

  require Logger

  import Ecto.Query, only: [where: 2]

  alias Streamix.Library.{Cipher, Key, KeyRecord}
  alias Streamix.Repo

  @salt_bytes 16
  @session_secret_bytes 32
  @bcrypt_password_bytes 72
  # OWASP's 2023 floor for PBKDF2-HMAC-SHA256. The test env lowers it.
  @default_iterations 600_000

  @doc """
  Unwraps the user's root key with their (already verified) password,
  creating one on first use.

  `{:error, :locked}` means a key exists that this password cannot open. It
  stays untouched: the library behind it is still the user's.
  """
  @spec unlock(integer(), String.t()) :: {:ok, Key.t()} | {:error, :locked}
  def unlock(user_id, password) when is_integer(user_id) and is_binary(password) do
    case Repo.get(KeyRecord, user_id) do
      nil ->
        create(user_id, password)

      %KeyRecord{} = record ->
        case unwrap(record, password) do
          {:ok, key} ->
            {:ok, key}

          :error ->
            Logger.warning(
              "[Library] the verified password does not open the stored library key",
              user_id: user_id
            )

            {:error, :locked}
        end
    end
  end

  @doc """
  Re-wraps the root key under `new_password`. The key, and therefore every
  sealed row, stays the same.
  """
  @spec rewrap(integer(), String.t(), String.t()) :: {:ok, Key.t()} | {:error, :locked}
  def rewrap(user_id, current_password, new_password)
      when is_integer(user_id) and is_binary(current_password) and is_binary(new_password) do
    with {:ok, key} <- unlock(user_id, current_password) do
      :ok = store(key, new_password)
      {:ok, key}
    end
  end

  @doc "Forgets the user's root key. Rows sealed under it become unreadable."
  @spec forget(integer()) :: :ok
  def forget(user_id) when is_integer(user_id) do
    KeyRecord |> where(user_id: ^user_id) |> Repo.delete_all()
    :ok
  end

  @doc """
  Wraps `key` under a fresh random session secret.

  Returns `{secret, sealed}`: the secret belongs to the client, the sealed
  blob to the session's token row.
  """
  @spec seal_session(Key.t()) :: {binary(), binary()}
  def seal_session(%Key{} = key) do
    secret = :crypto.strong_rand_bytes(@session_secret_bytes)
    {secret, Cipher.seal(session_key(secret), session_aad(key.user_id), key.root)}
  end

  @doc "Opens a session wrap with the client's secret."
  @spec open_session(integer(), binary() | nil, binary() | nil) :: {:ok, Key.t()} | :error
  def open_session(user_id, <<_::binary-size(@session_secret_bytes)>> = secret, sealed)
      when is_integer(user_id) and is_binary(sealed) do
    case Cipher.open(session_key(secret), session_aad(user_id), sealed) do
      {:ok, root} -> {:ok, Key.new(user_id, root)}
      :error -> :error
    end
  end

  def open_session(_user_id, _secret, _sealed), do: :error

  @doc "Byte size of a session secret."
  @spec session_secret_bytes() :: pos_integer()
  def session_secret_bytes, do: @session_secret_bytes

  defp create(user_id, password) do
    key = Key.generate(user_id)

    case Repo.insert_all(KeyRecord, [record_row(key, password)], on_conflict: :nothing) do
      {1, _} ->
        {:ok, key}

      # A concurrent login created the key first; open that one instead.
      {0, _} ->
        unlock(user_id, password)
    end
  end

  defp store(%Key{} = key, password) do
    row = record_row(key, password)

    Repo.insert_all(KeyRecord, [row],
      on_conflict: {:replace, [:salt, :iterations, :wrapped_key, :updated_at]},
      conflict_target: :user_id
    )

    :ok
  end

  defp record_row(%Key{} = key, password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    iterations = iterations()
    now = DateTime.utc_now(:second)

    %{
      user_id: key.user_id,
      salt: salt,
      iterations: iterations,
      wrapped_key:
        Cipher.seal(password_key(password, salt, iterations), password_aad(key.user_id), key.root),
      inserted_at: now,
      updated_at: now
    }
  end

  defp unwrap(%KeyRecord{} = record, password) do
    password
    |> password_key(record.salt, record.iterations)
    |> Cipher.open(password_aad(record.user_id), record.wrapped_key)
    |> case do
      {:ok, root} -> {:ok, Key.new(record.user_id, root)}
      :error -> :error
    end
  end

  defp password_key(password, salt, iterations) do
    :crypto.pbkdf2_hmac(:sha256, bcrypt_bytes(password), salt, iterations, 32)
  end

  # Bcrypt ignores everything past byte 72, so a longer password typed at
  # login passes verification. Deriving from the full input would then fail
  # to open a key wrapped under the stored (≤ 72-byte) password.
  defp bcrypt_bytes(password) when byte_size(password) > @bcrypt_password_bytes,
    do: binary_part(password, 0, @bcrypt_password_bytes)

  defp bcrypt_bytes(password), do: password

  defp session_key(secret), do: Cipher.hkdf(secret, "streamix/library/v1/session")

  defp password_aad(user_id), do: "library_key:password:user:#{user_id}"
  defp session_aad(user_id), do: "library_key:session:user:#{user_id}"

  defp iterations do
    Application.get_env(:streamix, :library_kdf_iterations, @default_iterations)
  end
end
