defmodule StreamixWeb.ChannelsLive do
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  @impl true
  def mount(_params, _session, socket) do
    user_id = 1

    filters = %{search: "", category: nil, provider_id: nil}
    channels = load_channels(user_id, filters, 1)
    categories = Iptv.list_categories(user_id)
    providers = Iptv.list_providers(user_id)
    favorite_ids = load_favorite_ids(user_id)

    {:ok,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:user_id, user_id)
     |> assign(:filters, filters)
     |> assign(:categories, categories)
     |> assign(:providers, providers)
     |> assign(:favorite_ids, favorite_ids)
     |> assign(:page, 1)
     |> assign(:has_more, length(channels) == 24)
     |> stream(:channels, channels)}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    filters = Map.put(socket.assigns.filters, :search, query)
    channels = load_channels(socket.assigns.user_id, filters, 1)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:page, 1)
     |> assign(:has_more, length(channels) == 24)
     |> stream(:channels, channels, reset: true)}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    category = if category == "", do: nil, else: category
    filters = Map.put(socket.assigns.filters, :category, category)
    channels = load_channels(socket.assigns.user_id, filters, 1)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:page, 1)
     |> assign(:has_more, length(channels) == 24)
     |> stream(:channels, channels, reset: true)}
  end

  @impl true
  def handle_event("filter_provider", %{"provider" => provider_id}, socket) do
    provider_id = if provider_id == "", do: nil, else: String.to_integer(provider_id)
    filters = Map.put(socket.assigns.filters, :provider_id, provider_id)
    channels = load_channels(socket.assigns.user_id, filters, 1)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:page, 1)
     |> assign(:has_more, length(channels) == 24)
     |> stream(:channels, channels, reset: true)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    page = socket.assigns.page + 1
    channels = load_channels(socket.assigns.user_id, socket.assigns.filters, page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:has_more, length(channels) == 24)
     |> stream(:channels, channels, at: -1)}
  end

  @impl true
  def handle_event("toggle_favorite", %{"id" => channel_id}, socket) do
    channel_id = String.to_integer(channel_id)
    user_id = socket.assigns.user_id

    case Iptv.toggle_favorite(user_id, channel_id) do
      {:ok, :added} ->
        {:noreply,
         socket
         |> update(:favorite_ids, &MapSet.put(&1, channel_id))
         |> put_flash(:info, "Added to favorites")}

      {:ok, :removed} ->
        {:noreply,
         socket
         |> update(:favorite_ids, &MapSet.delete(&1, channel_id))
         |> put_flash(:info, "Removed from favorites")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update favorite")}
    end
  end

  defp load_channels(user_id, filters, page) do
    opts =
      [limit: 24, offset: (page - 1) * 24]
      |> maybe_add_filter(:search, filters.search)
      |> maybe_add_filter(:category, filters.category)
      |> maybe_add_filter(:provider_id, filters.provider_id)

    Iptv.list_user_channels(user_id, opts)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp load_favorite_ids(user_id) do
    user_id
    |> Iptv.list_favorites(limit: 10_000)
    |> Enum.map(& &1.channel_id)
    |> MapSet.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil}>
      <.header>
        Channels
        <:subtitle>
          Browse your IPTV channels
        </:subtitle>
      </.header>

      <div class="flex flex-col sm:flex-row gap-4 mb-6">
        <div class="flex-1">
          <input
            type="search"
            name="search"
            value={@filters.search}
            placeholder="Search channels..."
            phx-change="search"
            phx-debounce="300"
            class="input input-bordered w-full"
          />
        </div>

        <select
          name="category"
          phx-change="filter_category"
          class="select select-bordered"
        >
          <option value="">All Categories</option>
          <option
            :for={category <- @categories}
            value={category}
            selected={@filters.category == category}
          >
            {category}
          </option>
        </select>

        <select
          name="provider"
          phx-change="filter_provider"
          class="select select-bordered"
        >
          <option value="">All Providers</option>
          <option
            :for={provider <- @providers}
            value={provider.id}
            selected={@filters.provider_id == provider.id}
          >
            {provider.name}
          </option>
        </select>
      </div>

      <div
        id="channels-grid"
        phx-update="stream"
        class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4"
      >
        <.channel_card
          :for={{dom_id, channel} <- @streams.channels}
          id={dom_id}
          channel={channel}
          favorited={MapSet.member?(@favorite_ids, channel.id)}
        />
      </div>

      <div :if={@has_more} class="text-center mt-8">
        <button phx-click="load_more" class="btn btn-ghost">
          Load More
        </button>
      </div>

      <.empty_state
        :if={Enum.empty?(@streams.channels |> Enum.to_list())}
        icon="hero-tv"
        title="No channels found"
        description="Try adjusting your filters or add a provider"
      >
        <:actions>
          <.link navigate={~p"/providers/new"} class="btn btn-primary">
            Add Provider
          </.link>
        </:actions>
      </.empty_state>
    </Layouts.app>
    """
  end
end
