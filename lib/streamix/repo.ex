defmodule Streamix.Repo do
  use Ecto.Repo,
    otp_app: :streamix,
    adapter: Ecto.Adapters.Postgres

  import Ecto.Query

  @doc """
  Wrapper around `transaction/1` for compatibility.
  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def transact(fun) when is_function(fun, 0) do
    transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> rollback(reason)
        other -> other
      end
    end)
  end

  @doc """
  Fetches all records matching the given clauses.

  ## Examples

      Repo.all_by(User, email: "test@example.com")
      Repo.all_by(UserToken, user_id: 123)

  """
  def all_by(schema, clauses) when is_atom(schema) and is_list(clauses) do
    schema |> where(^clauses) |> all()
  end
end
