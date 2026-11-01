defmodule Streamix.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Streamix.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.

  `library_key` is the user's unlocked `Streamix.Library.Key`, present for
  every authenticated session. Library operations take it instead of the user
  id, since history and favorites cannot be read without it.
  """

  alias Streamix.Accounts.User

  defstruct user: nil, library_key: nil

  @doc """
  Creates a scope for the given user and their unlocked library key.

  Returns nil if no user is given.
  """
  def for_user(user, library_key \\ nil)

  def for_user(%User{} = user, library_key) do
    %__MODULE__{user: user, library_key: library_key}
  end

  def for_user(nil, _library_key), do: nil
end
