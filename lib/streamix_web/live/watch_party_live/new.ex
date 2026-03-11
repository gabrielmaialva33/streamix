defmodule StreamixWeb.WatchPartyLive.New do
  @moduledoc """
  Creates a Watch Party room and redirects to the watch page.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.PlayerHelpers

  alias Streamix.WatchParty

  def mount(%{"type" => type, "id" => id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    case load_content(type, id, user_id) do
      {:ok, content, _provider, _stream_url} ->
        attrs = %{
          content_type: type,
          content_id: String.to_integer(id),
          content_name: content_title(content, type),
          content_icon: content_icon(content, type)
        }

        case WatchParty.create_room(user_id, attrs) do
          {:ok, room} ->
            {:ok, push_navigate(socket, to: ~p"/party/#{room.invite_code}/watch")}

          {:error, _changeset} ->
            {:ok,
             socket
             |> put_flash(:error, "Erro ao criar Watch Party")
             |> push_navigate(to: ~p"/")}
        end

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Conteúdo não encontrado")
         |> push_navigate(to: ~p"/")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-screen">
      <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-brand"></div>
    </div>
    """
  end
end
