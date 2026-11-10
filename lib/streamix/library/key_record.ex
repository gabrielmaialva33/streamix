defmodule Streamix.Library.KeyRecord do
  @moduledoc """
  A user's library root key, wrapped under a key derived from their password.

  `salt` and `iterations` are the PBKDF2 parameters used for this wrap, kept
  per row so the default can be raised without breaking existing users.
  """

  use Ecto.Schema

  @primary_key {:user_id, :id, autogenerate: false}
  schema "library_keys" do
    field :salt, :binary, redact: true
    field :iterations, :integer
    field :wrapped_key, :binary, redact: true

    timestamps(type: :utc_datetime)
  end
end
