defmodule StreamixWeb.Content.DetailComponents.Badges do
  @moduledoc """
  Compact metadata components shared by movie, series, and episode details.
  """

  use Phoenix.Component

  import StreamixWeb.CoreComponents, only: [icon: 1]

  attr :rating, :any, default: nil
  attr :class, :any, default: nil
  attr :divide_by_two?, :boolean, default: true

  def rating_badge(assigns) do
    assigns =
      assign(
        assigns,
        :display_rating,
        format_rating(assigns.rating, assigns.divide_by_two?)
      )

    ~H"""
    <span
      :if={@display_rating}
      class={[
        "inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-warning/10 text-warning rounded-md text-xs sm:text-sm font-semibold",
        @class
      ]}
    >
      <.icon name="hero-star-solid" class="size-3 sm:size-3.5" />
      {@display_rating}
    </span>
    """
  end

  attr :rating, :string, default: nil

  def content_rating_badge(assigns) do
    ~H"""
    <span
      :if={@rating}
      class={[
        "inline-flex items-center justify-center min-w-[36px] sm:min-w-[42px] h-6 sm:h-8 px-2 sm:px-2.5 rounded-md text-[10px] sm:text-xs font-bold",
        content_rating_class(@rating)
      ]}
      title="Classificação Indicativa"
    >
      {@rating}
    </span>
    """
  end

  attr :year, :any, default: nil

  def year_badge(assigns) do
    ~H"""
    <span
      :if={@year}
      class="inline-flex items-center h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-primary rounded-md text-xs sm:text-sm font-medium"
    >
      {@year}
    </span>
    """
  end

  attr :seconds, :integer, default: nil

  def duration_badge(assigns) do
    assigns = assign(assigns, :duration, format_duration(assigns.seconds))

    ~H"""
    <span
      :if={@duration}
      class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm"
    >
      <.icon name="hero-clock" class="size-3 sm:size-3.5" />{@duration}
    </span>
    """
  end

  attr :date, :any, default: nil

  def date_badge(assigns) do
    assigns = assign(assigns, :formatted_date, format_date(assigns.date))

    ~H"""
    <span
      :if={@formatted_date}
      class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm"
    >
      <.icon name="hero-calendar" class="size-3 sm:size-3.5" />{@formatted_date}
    </span>
    """
  end

  attr :extension, :string, default: nil

  def extension_badge(assigns) do
    ~H"""
    <span
      :if={@extension}
      class="inline-flex items-center h-6 sm:h-8 px-2 sm:px-2.5 bg-brand/20 text-brand rounded-md uppercase text-[10px] sm:text-xs font-bold"
    >
      {@extension}
    </span>
    """
  end

  attr :seasons, :list, default: []

  def series_count_badge(assigns) do
    assigns = assign(assigns, :episode_count, count_episodes(assigns.seasons))

    ~H"""
    <span class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm">
      <.icon name="hero-tv" class="size-3 sm:size-3.5" />
      {length(@seasons)} temp · {@episode_count} eps
    </span>
    """
  end

  @spec format_duration(integer() | term()) :: String.t() | nil
  def format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    total_minutes = div(seconds, 60)
    hours = div(total_minutes, 60)
    mins = rem(total_minutes, 60)

    cond do
      hours > 0 and mins > 0 -> "#{hours}h #{mins}min"
      hours > 0 -> "#{hours}h"
      true -> "#{mins}min"
    end
  end

  def format_duration(_), do: nil

  defp format_rating(nil, _divide_by_two?), do: nil

  defp format_rating(%Decimal{} = rating, true) do
    rating
    |> Decimal.div(2)
    |> Decimal.round(1)
    |> Decimal.to_string()
  end

  defp format_rating(%Decimal{} = rating, false) do
    rating
    |> Decimal.to_float()
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_rating(rating, true) when is_number(rating) do
    Float.round(rating / 2, 1) |> to_string()
  end

  defp format_rating(rating, false) when is_number(rating) do
    :erlang.float_to_binary(rating * 1.0, decimals: 1)
  end

  defp format_rating(_, _divide_by_two?), do: nil

  defp format_date(nil), do: nil
  defp format_date(date), do: Calendar.strftime(date, "%d/%m/%Y")

  defp content_rating_class(rating) when is_binary(rating) do
    case String.upcase(rating) do
      value when value in ["L", "G", "TV-G", "TV-Y", "TV-Y7"] -> "bg-success/10 text-success"
      value when value in ["10", "PG", "TV-PG"] -> "bg-info/10 text-info"
      value when value in ["12", "PG-13", "TV-14"] -> "bg-warning/10 text-warning"
      "14" -> "bg-warning/15 text-warning"
      value when value in ["16", "R", "TV-MA"] -> "bg-error/10 text-error"
      value when value in ["18", "NC-17"] -> "bg-error/15 text-error"
      _ -> "bg-surface text-text-secondary"
    end
  end

  defp content_rating_class(_), do: "bg-surface text-text-secondary"

  defp count_episodes(seasons) do
    Enum.sum(Enum.map(seasons, fn season -> length(season.episodes || []) end))
  end
end
