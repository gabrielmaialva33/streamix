defmodule StreamixWeb.UserAuth do
  @moduledoc """
  Plugs and functions for user authentication.
  """
  use StreamixWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  require Logger

  alias Streamix.Accounts

  # Session validity: 60 days
  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_streamix_user_remember_me"
  @remember_me_options [sign: true, max_age: @max_age, same_site: "Lax"]

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the renew_session
  function to customize this behaviour.

  It also sets a `:live_socket_id` key in the session,
  so LiveView sessions are identified and automatically
  disconnected on log out.
  """
  def log_in_user(conn, user, params \\ %{}) do
    # Capture IP and device info for the session
    ip_info = Accounts.request_info(conn)
    token = Accounts.generate_user_session_token(user, ip_info)
    user_return_to = get_session(conn, :user_return_to)

    # Log the login access asynchronously
    Accounts.log_access_async(conn, user.id)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params) do
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

    {user_token, conn} = ensure_user_token(conn)
    user_and_ts = user_token && Accounts.get_user_by_session_token(user_token)

    case user_and_ts do
      {user, token_inserted_at} ->
        scope = Accounts.scope_for_user(%{user | authenticated_at: token_inserted_at})
        Logger.metadata(user_id: user.id)

        conn
        |> assign(:current_scope, scope)
        |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(user_token)}")

      nil ->
        assign(conn, :current_scope, nil)
    end
  end

  defp ensure_user_token(conn) do
    case get_session(conn, :user_token) do
      nil ->
        conn = fetch_cookies(conn, signed: [@remember_me_cookie])

        case conn.cookies[@remember_me_cookie] do
          nil -> {nil, conn}
          token -> {token, put_token_in_session(conn, token)}
        end

      token ->
        {token, conn}
    end
  end

  defp put_token_in_session(conn, token) do
    put_session(conn, :user_token, token)
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
    socket = mount_current_scope(socket, session)

    # Pin user_id into Logger.metadata for this LiveView process so
    # every Logger.* call from handle_event / handle_info / render is
    # tagged. mount runs twice (static + WS) — Logger.metadata is
    # per-process so each pass attaches its own copy.
    if socket.assigns[:current_scope] do
      Logger.metadata(user_id: socket.assigns.current_scope.user.id)
    end

    {:cont, socket}
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
      user_token = session["user_token"]
      user_and_ts = user_token && Accounts.get_user_by_session_token(user_token)

      case user_and_ts do
        {user, token_inserted_at} ->
          Accounts.scope_for_user(%{user | authenticated_at: token_inserted_at})

        nil ->
          nil
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

  defp signed_in_path(_conn), do: ~p"/"
end
