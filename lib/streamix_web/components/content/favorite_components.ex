defmodule StreamixWeb.Content.FavoriteComponents do
  @moduledoc "Favorites preserve the compact home shelf and the actionable library grid."
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.CoreComponents
  alias StreamixWeb.Content.DisplayTitle
  alias StreamixWeb.Helpers.ImageProxy
  alias StreamixWeb.Home.Helpers, as: HomeHelpers

  @doc "The shelf links directly to playback; the library emits play/remove events and adapts to the content aspect ratio."
  attr :favorite, :map, required: true
  attr :variant, :atom, values: [:shelf, :library], default: :shelf
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def favorite_item(%{variant: :shelf} = assigns) do
    assigns =
      assigns
      |> assign(:image_url, ImageProxy.browser_image(assigns.favorite.content_icon))

    ~H"""
    <.link
      href={HomeHelpers.watch_path(@favorite.content_type, @favorite.content_id)}
      class={[
        "content-card media-shelf-card media-shelf-card--favorite group overflow-hidden rounded-md bg-surface transition-transform duration-300 hover:-translate-y-1 sm:rounded-lg",
        @class
      ]}
    >
      <div class="relative flex aspect-[2/3] items-center justify-center bg-surface-hover">
        <div
          id={"fav-img-#{@favorite.content_type}-#{@favorite.content_id}"}
          phx-hook="ImageFallback"
          class="w-full h-full"
        >
          <img
            :if={@image_url}
            src={@image_url}
            alt={@favorite.content_name}
            class="w-full h-full object-cover"
            loading="lazy"
            decoding="async"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex items-center justify-center text-text-muted",
              @image_url && "hidden"
            ]}
          >
            <.icon
              name={HomeHelpers.content_type_icon(@favorite.content_type)}
              class="size-6 sm:size-10"
            />
          </div>
        </div>
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white/90 drop-shadow-lg" />
        </div>
      </div>
    </.link>
    """
  end

  def favorite_item(%{variant: :library} = assigns) do
    assigns =
      assigns
      |> assign(:poster?, assigns.favorite.content_type in ["movie", "series"])
      |> assign(
        :image_url,
        case assigns.favorite.content_icon do
          icon when is_binary(icon) and icon != "" -> ImageProxy.proxy(icon)
          _other -> nil
        end
      )
      |> assign(:title, favorite_display_title(assigns.favorite))

    ~H"""
    <.poster_media_card
      :if={@poster?}
      id={@id}
      image_id={"favorite-image-#{@favorite.content_type}-#{@favorite.content_id}"}
      title={@title}
      image_url={@image_url}
      fallback_icon={content_type_icon(@favorite.content_type)}
      content_id={@favorite.content_id}
      content_type={@favorite.content_type}
      on_click="play"
      data-favorite-kind="poster"
      class="catalog-stream-item catalog-stream-item--poster self-start border border-transparent hover:border-border"
    >
      <:metadata>
        <div class="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs text-text-muted">
          <span
            data-favorite-type-badge
            class="rounded bg-surface-hover px-1.5 py-0.5 text-2xs font-medium text-text-secondary"
          >
            {format_content_type(@favorite.content_type)}
          </span>
        </div>
      </:metadata>
      <:secondary_action>
        <.remove_favorite_button favorite={@favorite} />
      </:secondary_action>
    </.poster_media_card>

    <.landscape_media_card
      :if={!@poster?}
      id={@id}
      image_id={"favorite-image-#{@favorite.content_type}-#{@favorite.content_id}"}
      title={@title}
      image_url={@image_url}
      image_fit={if @favorite.content_type == "live_channel", do: "contain", else: "cover"}
      fallback_icon={content_type_icon(@favorite.content_type)}
      content_id={@favorite.content_id}
      content_type={@favorite.content_type}
      on_click="play"
      data-favorite-kind="wide"
      class="catalog-stream-item catalog-stream-item--wide self-start border border-transparent hover:border-border"
    >
      <:metadata>
        <div class="mt-2 flex flex-wrap items-center gap-2 text-xs text-text-muted">
          <span
            data-favorite-type-badge
            class="rounded bg-surface-hover px-1.5 py-0.5 text-2xs font-medium text-text-secondary"
          >
            {format_content_type(@favorite.content_type)}
          </span>
        </div>
      </:metadata>
      <:secondary_action>
        <.remove_favorite_button favorite={@favorite} />
      </:secondary_action>
    </.landscape_media_card>
    """
  end

  attr :favorite, :map, required: true

  defp remove_favorite_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="remove_favorite"
      phx-value-type={@favorite.content_type}
      phx-value-content_id={@favorite.content_id}
      data-touch-visible="true"
      class="flex size-11 items-center justify-center rounded-full bg-surface/90 text-text-secondary opacity-100 shadow-sm backdrop-blur-sm transition-all hover:bg-error/15 hover:text-error focus:outline-none focus:ring-2 focus:ring-error"
      aria-label="Remover dos favoritos"
    >
      <.icon name="hero-trash" class="size-4" />
    </button>
    """
  end

  defp favorite_display_title(%{content_type: "live_channel", content_name: name})
       when is_binary(name) and name != "" do
    name |> DisplayTitle.channel() |> fallback_title()
  end

  defp favorite_display_title(%{content_type: "episode", content_name: name})
       when is_binary(name) and name != "" do
    name |> DisplayTitle.episode() |> fallback_title()
  end

  defp favorite_display_title(%{content_name: name}) when is_binary(name) and name != "" do
    name |> DisplayTitle.title() |> fallback_title()
  end

  defp favorite_display_title(_favorite), do: "Desconhecido"

  defp fallback_title(""), do: "Desconhecido"
  defp fallback_title(title), do: title

  defp content_type_icon("live_channel"), do: "hero-tv"
  defp content_type_icon("movie"), do: "hero-film"
  defp content_type_icon("series"), do: "hero-video-camera"
  defp content_type_icon("episode"), do: "hero-play"
  defp content_type_icon(_), do: "hero-play-circle"

  defp format_content_type("live_channel"), do: "Ao Vivo"
  defp format_content_type("movie"), do: "Filme"
  defp format_content_type("series"), do: "Série"
  defp format_content_type("episode"), do: "Episódio"
  defp format_content_type(type), do: type || "Desconhecido"
end
