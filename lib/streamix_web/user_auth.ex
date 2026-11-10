defmodule StreamixWeb.UserAuth do
  @moduledoc """
  Plugs and functions for user authentication.
  """
  use StreamixWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Streamix.Accounts
  alias Streamix.Library

  # Encrypted, not just signed: it carries the session's library secret.
  @remember_me_cookie "_streamix_user_remember_me"
  @remember_me_options [
    encrypt: true,
    same_site: "Lax",
    secure: Application.compile_env(:streamix, :session_secure, true),
    http_only: true
  ]

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the renew_session
  function to customize this behaviour.

  It also sets a `:live_socket_id` key in the session,
  so LiveView sessions are identified and automatically
  disconnected on log out.

  `library_key` is the user's library key, unlocked with the password they
  just typed (`Streamix.Library.unlock/2`). The session stores it wrapped
  under a fresh secret that only this browser keeps, in the session cookie.
  """
  def log_in_user(conn, user, library_key, params \\ %{}) do
    # Capture IP and device info for the session
    ip_info = Accounts.request_info(conn)
    {library_secret, sealed_library_key} = Library.seal_session(library_key)
    token = Accounts.generate_user_session_token(user, ip_info, sealed_library_key)
    user_return_to = get_session(conn, :user_return_to)

    # Log the login access asynchronously
    Accounts.log_access_async(conn, user.id)

    conn
    |> renew_session()
    |> put_credentials_in_session(token, library_secret)
    |> maybe_write_remember_me_cookie({token, library_secret}, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  defp maybe_write_remember_me_cookie(conn, credentials, %{"remember_me" => "true"}) do
    options = Keyword.put(@remember_me_options, :max_age, Accounts.session_max_age_seconds())
    put_resp_cookie(conn, @remember_me_cookie, credentials, options)
  end

  defp maybe_write_remember_me_cookie(conn, _credentials, _params) do
    conn
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      StreamixWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session
  and remember me token.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    # Plug.RequestId (mounted earlier in the endpoint pipeline) already
    # set the `request_id` resp header — copy it into Logger metadata so
    # every Logger call later in the request/LV mount chain inherits it.
    # Without this, the per-request `request_id` ends up on the wire but
    # never in our log lines.
    case Plug.Conn.get_resp_header(conn, "x-request-id") do
      [request_id | _] -> Logger.metadata(request_id: request_id)
      _ -> :ok
    end

    # Deliberately no `user_id` in Logger metadata: request lines carry paths
    # such as /watch/movie/123, and tagging them with the user would put in
    # the logs exactly what the sealed library keeps from the operator.
    {user_token, library_secret, conn} = ensure_credentials(conn)

    case scope_for_session(user_token, library_secret) do
      {:ok, scope} ->
        conn
        |> assign(:current_scope, scope)
        |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(user_token)}")

      :locked ->
        # A session from before the library was encrypted, or one whose
        # secret is gone: it can never open the library, so it ends here and
        # the user logs in again.
        Accounts.delete_user_session_token(user_token)

        conn
        |> delete_session(:user_token)
        |> delete_session(:library_secret)
        |> delete_resp_cookie(@remember_me_cookie)
        |> assign(:current_scope, nil)

      :none ->
        assign(conn, :current_scope, nil)
    end
  end

  defp ensure_credentials(conn) do
    case get_session(conn, :user_token) do
      nil ->
        conn = fetch_cookies(conn, encrypted: [@remember_me_cookie])

        case conn.cookies[@remember_me_cookie] do
          {token, library_secret} when is_binary(token) and is_binary(library_secret) ->
            {token, library_secret, put_credentials_in_session(conn, token, library_secret)}

          _ ->
            {nil, nil, conn}
        end

      token ->
        {token, get_session(conn, :library_secret), conn}
    end
  end

  defp put_credentials_in_session(conn, token, library_secret) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:library_secret, library_secret)
  end

  defp scope_for_session(nil, _library_secret), do: :none

  defp scope_for_session(user_token, library_secret) do
    case Accounts.get_session_by_token(user_token) do
      {user, token_inserted_at, sealed_library_key} ->
        case Library.open_session(user.id, library_secret, sealed_library_key) do
          {:ok, library_key} ->
            {:ok,
             Accounts.scope_for_user(%{user | authenticated_at: token_inserted_at}, library_key)}

          :error ->
            :locked
        end

      nil ->
        :none
    end
  end

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope to socket assigns based on
      user_token, or nil if there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based on user_token.
      Redirects to login page if there's no logged user.

    * `:redirect_if_authenticated` - Authenticates the user from the session.
      Redirects to signed_in_path if there's a logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the current_scope:

      defmodule StreamixWeb.PageLive do
        use StreamixWeb, :live_view

        on_mount {StreamixWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{StreamixWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    # No `user_id` in Logger metadata here either: LiveView events name the
    # content being played. See fetch_current_scope_for_user/2.
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          "Você precisa fazer login para acessar esta página."
        )
        |> Phoenix.LiveView.redirect(to: ~p"/login")

      {:halt, socket}
    end
  end

  def on_mount(:require_admin, _params, _session, socket) do
    if socket.assigns.current_scope &&
         Accounts.admin?(socket.assigns.current_scope.user) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Acesso restrito a administradores.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      case scope_for_session(session["user_token"], session["library_secret"]) do
        {:ok, scope} -> scope
        _locked_or_none -> nil
      end
    end)
  end

  @doc """
  Used for routes that require the user to not be authenticated.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
    else
      conn
      |> put_flash(:error, "Você precisa fazer login para acessar esta página.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(_conn), do: ~p"/home"
end
