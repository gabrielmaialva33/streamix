defmodule StreamixWeb.LiveSessionNavigation do
  @moduledoc """
  Classifies browser paths by Phoenix `live_session`.

  LiveView can't perform `push_navigate/2` across sessions with different
  `on_mount` hooks. Callers use this classifier to choose a LiveView
  navigation only within the same session and a normal HTTP navigation at
  authentication, admin, public, or player boundaries.
  """

  @public_paths ~w(/ /plans /tv)
  @guest_paths ~w(/login /register)

  @spec same_session?(String.t() | nil, String.t() | nil) :: boolean()
  def same_session?(from, to) do
    from_session = session(from)
    from_session != :unknown and from_session == session(to)
  end

  @doc """
  Applies the correct server-side navigation primitive for two browser paths.
  """
  @spec navigate(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def navigate(socket, from, to) do
    if same_session?(from, to) do
      Phoenix.LiveView.push_navigate(socket, to: to)
    else
      Phoenix.LiveView.redirect(socket, to: to)
    end
  end

  @spec session(String.t() | nil) ::
          :public | :guest | :authenticated | :authenticated_player | :admin | :unknown
  def session(path) when is_binary(path) do
    path = URI.parse(path).path || ""

    cond do
      path in @public_paths -> :public
      path in @guest_paths -> :guest
      String.starts_with?(path, "/admin") -> :admin
      String.starts_with?(path, "/watch/") -> :authenticated_player
      Regex.match?(~r{^/party/[^/]+/watch$}, path) -> :authenticated_player
      String.starts_with?(path, "/") -> :authenticated
      true -> :unknown
    end
  end

  def session(_path), do: :unknown
end
