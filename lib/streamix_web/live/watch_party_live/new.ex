defmodule StreamixWeb.WatchPartyLive.New do
  @moduledoc """
  Creates a Watch Party room and redirects to the watch page.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]
  import StreamixWeb.PlayerHelpers

  alias Streamix.Iptv.ContentRef
  alias Streamix.WatchParty

  def mount(%{"type" => type, "id" => id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    socket = assign(socket, current_path: "/party")

    with {:ok, content_id} <- parse_positive_integer(id),
         {:ok, content, _provider, _stream_url} <- load_content(type, id, user_id),
         {:ok, catalog_item_id} <- ContentRef.resolve_catalog_item_id(type, content_id),
         attrs = %{
           catalog_item_id: catalog_item_id,
           content_name: content_title(content, type),
           content_icon: content_icon(content, type)
         },
         {:ok, room} <- WatchParty.create_room(user_id, attrs) do
      {:ok, push_navigate(socket, to: ~p"/party/#{room.invite_code}/watch")}
    else
      {:error, :watch_party_not_allowed} ->
        {:ok,
         socket
         |> put_flash(:error, "Watch Party exige um plano com esse recurso.")
         |> push_navigate(to: ~p"/plans?upgrade=watch_party")}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Erro ao criar Watch Party")
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
