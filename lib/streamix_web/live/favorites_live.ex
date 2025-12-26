defmodule StreamixWeb.FavoritesLive do
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  @impl true
  def mount(_params, _session, socket) do
    user_id = 1
    favorites = Iptv.list_favorites(user_id)

    {:ok,
     socket
     |> assign(:page_title, "Favorites")
     |> assign(:user_id, user_id)
     |> stream(:favorites, favorites)}
  end

  @impl true
  def handle_event("toggle_favorite", %{"id" => channel_id}, socket) do
    channel_id = String.to_integer(channel_id)
    user_id = socket.assigns.user_id

    case Iptv.remove_favorite(user_id, channel_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> stream_delete_by_dom_id(:favorites, "favorites-#{channel_id}")
         |> put_flash(:info, "Removed from favorites")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove favorite")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil}>
      <.header>
        Favorites
        <:subtitle>
          Your favorite channels
        </:subtitle>
      </.header>

      <div
        id="favorites-grid"
        phx-update="stream"
        class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4"
      >
        <.channel_card
          :for={{dom_id, favorite} <- @streams.favorites}
          id={dom_id}
          channel={favorite.channel}
          favorited={true}
        />
      </div>

      <.empty_state
        :if={Enum.empty?(@streams.favorites |> Enum.to_list())}
        icon="hero-heart"
        title="No favorites yet"
        description="Browse channels and add some to your favorites"
      >
        <:actions>
          <.link navigate={~p"/channels"} class="btn btn-primary">
            Browse Channels
          </.link>
        </:actions>
      </.empty_state>
    </Layouts.app>
    """
  end
end
