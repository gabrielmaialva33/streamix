defmodule StreamixWeb.UserSessionController do
  use StreamixWeb, :controller

  alias Streamix.{Accounts, Library}
  alias StreamixWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      # The password is only ever in hand here, so this is where the library
      # key gets unlocked.
      case Library.unlock(user, password) do
        {:ok, library_key} ->
          conn
          |> put_flash(:info, "Bem-vindo de volta!")
          |> UserAuth.log_in_user(user, library_key, user_params)

        {:error, :locked} ->
          conn
          |> put_flash(:error, "Não foi possível abrir sua biblioteca com esta senha.")
          |> redirect(to: ~p"/login")
      end
    else
      conn
      |> put_flash(:error, "Email ou senha inválidos")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logout realizado com sucesso.")
    |> UserAuth.log_out_user()
  end
end
