defmodule StreamixWeb.Content.ReelsLive do
  @moduledoc """
  "Dramas curtos": vertical short-drama series at `/browse/reels`.

  Providers tag these series with `[Reels] ...` categories. The chips merge
  those categories across every provider the user can browse, so the filter
  works in the unified catalog where the provider-scoped series category
  filter cannot. Cards open the regular series detail page.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.App.Feedback
  import StreamixWeb.App.Premium
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.Content.NavigationComponents
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  alias Streamix.Library
  alias StreamixWeb.Content.Browse
  alias StreamixWeb.Content.Detail
  alias StreamixWeb.Content.HelperComponents

  @browse_path "/browse/reels"
  @per_page 48
  @max_restore_pages 25
  # Matches the domain bound: a display name of a varchar(255) category.
  @max_category_length 247

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    global_provider = Streamix.Providers.get_global_provider()

    {:ok,
     socket
     |> assign(page_title: "Dramas curtos")
     |> assign(current_path: @browse_path)
     |> assign(user: user)
     |> assign(user_id: user.id)
     |> assign(premium_access: Detail.premium_access?(user))
     |> assign(global_provider_id: global_provider && global_provider.id)
     |> assign(tab_counts: tab_counts(user.id))
     |> assign(
       categories:
         Streamix.Catalog.list_visible_reel_categories(user.id,
           show_adult: user.show_adult_content
         )
     )
     |> assign(favorites_map: Library.list_favorite_ids(user.id, "series"))
     |> assign(selected_category: nil)
     |> assign(page: 1)
     |> assign(has_more: false)
     |> assign(loading: false)
     |> assign(empty_results: false)
     |> stream(:series, [])}
  end

  def handle_params(params, _url, socket) do
    category = normalize_category(params["category"])

    socket =
      socket
      |> assign(selected_category: category)
      |> assign(current_path: reels_path(category, 1))
      |> assign(page: 1)
      |> assign(has_more: true)
      |> assign(empty_results: false)
      |> stream(:series, [], reset: true)
      |> load_through_page(restore_page(params["page"]))

    {:noreply, socket}
  end

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("load_more", _params, socket) do
    socket =
      if socket.assigns.loading or not socket.assigns.has_more do
        socket
      else
        load_page(socket, socket.assigns.page + 1)
      end

    {:reply, %{page: socket.assigns.page}, socket}
  end

  # `view_series` comes from the card itself and from the hover preview's
  # play button; `show_details` from the preview's details button.
  def handle_event(event, %{"id" => id}, socket) when event in ["view_series", "show_details"] do
    case parse_positive_integer(id) do
      {:ok, series_id} ->
        {:noreply, push_navigate(socket, to: detail_path(socket.assigns, series_id))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => "series"}, socket) do
    {:noreply, Browse.toggle_favorite(socket, :series, id)}
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div id="reels-browse" phx-hook="BrowseScrollRestoration" class="space-y-4 sm:space-y-5">
      <div class="browse-toolbar">
        <div class="browse-toolbar__row">
          <.source_tabs selected="iptv" path={~p"/browse/reels"} gindex_path={~p"/browse/movies"} />
          <div class="browse-toolbar__divider" />
          <.browse_tabs selected={:reels} source="iptv" counts={@tab_counts} />
        </div>

        <.premium_cta_banner
          :if={not @premium_access}
          id="reels-premium-cta"
          current_scope={@current_scope}
        />
      </div>

      <header class="space-y-1">
        <h1 class="flex items-center gap-2 text-xl font-semibold text-text-primary sm:text-2xl">
          <.icon name="hero-device-phone-mobile" class="size-5 text-brand sm:size-6" /> Dramas curtos
        </h1>
        <p class="text-sm text-text-secondary">
          Novelas verticais com episódios de poucos minutos.
        </p>
      </header>

      <nav
        :if={@categories != []}
        id="reel-categories"
        aria-label="Categorias de dramas curtos"
        class="filter-strip"
      >
        <.link
          id="reel-category-all"
          patch={~p"/browse/reels"}
          aria-current={is_nil(@selected_category) && "page"}
          class={["category-chip", is_nil(@selected_category) && "category-chip--active"]}
        >
          Todas
        </.link>
        <.link
          :for={category <- @categories}
          id={category_dom_id(category.name)}
          data-category={category.name}
          patch={reels_path(category.name, 1)}
          aria-current={@selected_category == category.name && "page"}
          class={[
            "category-chip gap-1.5",
            @selected_category == category.name && "category-chip--active"
          ]}
        >
          <span>{category.name}</span>
          <span class="text-[11px] font-semibold tabular-nums opacity-70">
            {HelperComponents.format_count(category.count)}
          </span>
        </.link>
      </nav>

      <div id="reels-grid" phx-update="stream" class="responsive-poster-grid">
        <div
          :for={{dom_id, series} <- @streams.series}
          id={dom_id}
          class="catalog-stream-item catalog-stream-item--poster"
        >
          <.series_card
            series={series}
            is_favorite={MapSet.member?(@favorites_map, series.id)}
            source="iptv"
            show_premium_badge={premium_badge?(series, @premium_access, @global_provider_id)}
          />
        </div>
      </div>

      <.infinite_scroll_sentinel
        :if={@has_more && !@loading}
        id="reels-sentinel"
        page={@page}
        sync_page_url={true}
        stream_target="#reels-grid"
      />

      <.empty_state
        :if={@empty_results}
        icon="hero-device-phone-mobile"
        title="Nenhum drama curto encontrado"
        message={empty_message(@selected_category)}
      >
        <:action :if={@selected_category}>
          <.link
            id="reels-empty-reset"
            patch={~p"/browse/reels"}
            class="inline-flex min-h-11 items-center rounded-lg bg-brand px-5 py-2 text-sm font-medium text-white transition-colors hover:bg-brand-hover"
          >
            Ver todos os dramas curtos
          </.link>
        </:action>
      </.empty_state>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp load_through_page(socket, target_page) do
    Enum.reduce_while(1..target_page, socket, fn page, socket ->
      if page == 1 or socket.assigns.has_more do
        {:cont, load_page(socket, page)}
      else
        {:halt, socket}
      end
    end)
  end

  defp load_page(socket, page) do
    user = socket.assigns.user

    items =
      Streamix.Catalog.list_visible_reel_series(user.id,
        category: socket.assigns.selected_category,
        show_adult: user.show_adult_content,
        limit: @per_page,
        offset: (page - 1) * @per_page
      )

    socket
    |> stream(:series, items)
    |> assign(page: page)
    |> assign(has_more: length(items) >= @per_page)
    |> assign(loading: false)
    |> assign(empty_results: page == 1 and items == [])
  end

  defp detail_path(assigns, id) do
    return_to = reels_path(assigns.selected_category, assigns.page)
    "/browse/series/#{id}?" <> URI.encode_query(%{"return_to" => return_to})
  end

  defp reels_path(category, page) do
    params =
      %{}
      |> put_present("category", category)
      |> put_present("page", page > 1 && page)

    case params do
      empty when map_size(empty) == 0 -> @browse_path
      params -> @browse_path <> "?" <> URI.encode_query(params)
    end
  end

  defp put_present(params, _key, value) when value in [nil, false, ""], do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  defp tab_counts(user_id) do
    providers =
      user_id
      |> Streamix.Providers.list_visible_providers()
      |> Enum.filter(&(&1.provider_type == :xtream))

    Browse.counts(
      %{mode: :browse, source: "iptv", provider_filter: "all", provider_options: providers},
      :series
    )
  end

  # Mirrors the series browse convention, scoped to titles the plan gates:
  # only global-provider content needs an upgrade.
  defp premium_badge?(_series, true, _global_provider_id), do: false
  defp premium_badge?(_series, _premium_access, nil), do: false
  defp premium_badge?(series, _premium_access, global_id), do: series.provider_id == global_id

  defp empty_message(nil), do: "Os dramas curtos aparecem aqui assim que um provedor sincronizar."

  defp empty_message(category),
    do: "Nenhum título disponível em \"#{category}\" no momento."

  defp normalize_category(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      category -> String.slice(category, 0, @max_category_length)
    end
  end

  defp normalize_category(_value), do: nil

  defp restore_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 1 -> min(page, @max_restore_pages)
      _ -> 1
    end
  end

  defp restore_page(_page), do: 1

  # A slug would merge "Ação" with "Acao" and leave CJK names empty, so the
  # id hashes the full name; hex never spells the fixed "all" chip.
  defp category_dom_id(name) do
    digest = :crypto.hash(:sha256, name) |> binary_part(0, 6) |> Base.encode16(case: :lower)
    "reel-category-" <> digest
  end
end
