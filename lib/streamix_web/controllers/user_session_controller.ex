defmodule StreamixWeb.UserSessionController do
  use StreamixWeb, :controller

  alias Streamix.Accounts
  alias StreamixWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, "Bem-vindo de volta!")
      |> UserAuth.log_in_user(user, user_params)
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
