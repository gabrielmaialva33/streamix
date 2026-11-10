defmodule Streamix.Library.Key do
  @moduledoc """
  A user's unlocked library key.

  The root secret is a random 32-byte key generated for each user. It is only
  ever stored wrapped: under a key derived from the user's password
  (`library_keys`) and under a per-session secret that only the client holds
  (`users_tokens.library_key`). Neither wrap can be opened with what the
  database, the logs or the application configuration contain.

  Two subkeys are derived from the root with HKDF so one never doubles as the
  other: `encryption_key` seals library rows and `index_key` computes the
  blind indexes used to look a row up without revealing which content it
  points at.

  The struct only lives in memory for the duration of a request or a LiveView
  process. `Inspect` shows nothing but the user id, so a crash report or an
  `inspect/1` in a log line cannot leak the secret.
  """

  alias Streamix.Library.Cipher

  @derive {Inspect, only: [:user_id]}
  @enforce_keys [:user_id, :root, :encryption_key, :index_key]
  defstruct [:user_id, :root, :encryption_key, :index_key]

  @type t :: %__MODULE__{
          user_id: integer(),
          root: binary(),
          encryption_key: binary(),
          index_key: binary()
        }

  @root_bytes 32

  @doc "Generates a fresh random root key for `user_id`."
  @spec generate(integer()) :: t()
  def generate(user_id) when is_integer(user_id) do
    new(user_id, :crypto.strong_rand_bytes(@root_bytes))
  end

  @doc "Builds a key from an already unwrapped 32-byte root secret."
  @spec new(integer(), binary()) :: t()
  def new(user_id, <<_::binary-size(@root_bytes)>> = root) when is_integer(user_id) do
    %__MODULE__{
      user_id: user_id,
      root: root,
      encryption_key: Cipher.hkdf(root, "streamix/library/v1/encryption"),
      index_key: Cipher.hkdf(root, "streamix/library/v1/index")
    }
  end
end
