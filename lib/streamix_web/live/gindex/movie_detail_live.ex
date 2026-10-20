defmodule StreamixWeb.Gindex.MovieDetailLive do
  @moduledoc """
  LiveView for displaying GIndex movie details.
  """
  use StreamixWeb, :live_view
  alias Streamix.Library
  alias StreamixWeb.Content.FavoriteState
  alias StreamixWeb.Content.SourceBadges
  alias StreamixWeb.Gindex.DetailHelpers, as: DH

  import StreamixWeb.CoreComponents, only: [badge: 1, icon: 1]

  import StreamixWeb.Content.DetailComponents,
    only: [detail_hero: 1, detail_title: 1, synopsis_section: 1]

  import StreamixWeb.Content.DetailComponents.Actions, only: [favorite_button: 1, play_button: 1]

  import StreamixWeb.Content.DetailComponents.Badges,
    only: [extension_badge: 1, rating_badge: 1, year_badge: 1]

  def mount(%{"id" => movie_id} = params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    return_to = safe_return_path(params["return_to"])

    case Streamix.Catalog.get_movie(movie_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Filme não encontrado")
         |> push_navigate(to: ~p"/gindex/movies")}

      movie ->
        if is_nil(movie.gindex_path) do
          {:ok,
           socket
           |> put_flash(:error, "Filme não pertence ao GIndex")
           |> push_navigate(to: ~p"/gindex/movies")}
        else
          is_favorite = Library.favorite?(user_id, "movie", movie.id)
          movie = Streamix.Catalog.get_movie_with_provider!(movie.id)
          display_title = DH.display_title_movie(movie)

          socket =
            socket
            |> assign(page_title: display_title)
            |> assign(
              current_path: with_return_to(~p"/gindex/movies/#{movie.id}", return_to),
              return_to: return_to
            )
            |> assign(movie: movie)
            |> assign(lcp_image: movie.stream_icon)
            |> assign(display_title: display_title)
            |> assign(source_badges: SourceBadges.badges(movie))
            |> assign(is_favorite: is_favorite)
            |> assign(user_id: user_id)

          {:ok, socket}
        end
    end
  end

  def handle_event("play_movie", _, socket) do
    {:noreply,
     redirect(socket,
       to:
         with_return_to(
           ~p"/watch/gindex/#{socket.assigns.movie.id}",
           socket.assigns.current_path
         )
     )}
  end

  def handle_event("toggle_favorite", _, socket) do
    user_id = socket.assigns.user_id
    movie = socket.assigns.movie
    is_favorite = socket.assigns.is_favorite

    result =
      FavoriteState.toggle(user_id, "movie", movie.id, %{
        content_name: movie.title || movie.name,
        content_icon: movie.stream_icon
      })

    {:noreply, assign(socket, is_favorite: FavoriteState.preserve_boolean(is_favorite, result))}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <.detail_hero
        image={@movie.stream_icon}
        alt={@display_title}
        back_path={@return_to || ~p"/browse/movies?source=gindex"}
      />

      <div class="relative -mt-16 sm:-mt-32 lg:-mt-40 px-3 sm:px-8 lg:px-12 pb-6 sm:pb-12">
        <div class="max-w-7xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-3 sm:gap-6 lg:gap-8">
            <div class="flex-shrink-0 w-24 sm:w-48 lg:w-72 mx-auto lg:mx-0">
              <div class="aspect-[2/3] rounded-lg sm:rounded-xl overflow-hidden shadow-2xl ring-1 ring-white/10 bg-surface">
                <img
                  :if={@movie.stream_icon}
                  src={@movie.stream_icon}
                  alt={@display_title}
                  class="w-full h-full object-cover"
                  loading="lazy"
                  referrerpolicy="no-referrer"
                />
                <div
                  :if={is_nil(@movie.stream_icon)}
                  class="w-full h-full flex items-center justify-center bg-surface-hover"
                >
                  <.icon name="hero-film" class="size-12 sm:size-16 text-text-secondary/30" />
                </div>
              </div>
            </div>

            <div class="flex-1 space-y-2 sm:space-y-4 lg:space-y-6 text-center lg:text-left">
              <.detail_title title={@display_title} />

              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2">
                <.rating_badge rating={@movie.rating} />
                <.year_badge year={@movie.year} />
                <.extension_badge extension={@movie.container_extension} />
                <.badge
                  :for={badge <- @source_badges}
                  variant="surface"
                  size="sm"
                  data-source-badge
                >
                  {badge}
                </.badge>
              </div>

              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <.play_button event="play_movie" label="Assistir" />
                <div class="title-secondary-actions">
                  <StreamixWeb.WatchPartyComponents.create_party_button
                    content_type="gindex"
                    content_id={@movie.id}
                  />
                  <.favorite_button favorite?={@is_favorite} />
                </div>
              </div>

              <.synopsis_section text={@movie.plot} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp with_return_to(path, return_to) when is_binary(return_to) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "return_to=" <> URI.encode_www_form(return_to)
  end

  defp with_return_to(path, _return_to), do: path

  defp safe_return_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"), do: path
  end

  defp safe_return_path(_path), do: nil
end
