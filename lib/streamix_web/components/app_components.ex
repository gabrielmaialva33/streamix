defmodule StreamixWeb.AppComponents do
  @moduledoc """
  Application-specific UI components for Streamix.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: StreamixWeb.Endpoint,
    router: StreamixWeb.Router,
    statics: StreamixWeb.static_paths()

  import StreamixWeb.CoreComponents

  @doc """
  Renders a card container with optional title.
  """
  attr :class, :string, default: nil
  attr :title, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  def card(assigns) do
    ~H"""
    <div class={["card bg-base-200", @class]}>
      <div class="card-body">
        <div :if={@title || @actions != []} class="flex items-center justify-between mb-4">
          <h3 :if={@title} class="card-title text-base">{@title}</h3>
          <div :if={@actions != []} class="flex gap-2">
            {render_slot(@actions)}
          </div>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a stat item for the dashboard.
  """
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :class, :string, default: nil

  def stat_item(assigns) do
    ~H"""
    <div class={["stat", @class]}>
      <div class="stat-figure text-primary">
        <.icon name={@icon} class="size-8" />
      </div>
      <div class="stat-title">{@title}</div>
      <div class="stat-value text-primary">{@value}</div>
    </div>
    """
  end

  @doc """
  Renders an empty state placeholder.
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class="text-center py-12">
      <.icon name={@icon} class="size-16 text-base-content/30 mx-auto mb-4" />
      <h3 class="text-lg font-medium text-base-content/60">{@title}</h3>
      <p :if={@description} class="text-base-content/50 mt-1">{@description}</p>
      <div :if={@actions != []} class="mt-4">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a channel card for displaying IPTV channels.
  """
  attr :channel, :map, required: true
  attr :favorited, :boolean, default: false
  attr :show_provider, :boolean, default: false
  attr :id, :string, default: nil

  def channel_card(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-200 hover:bg-base-300 transition cursor-pointer group">
      <.link navigate={~p"/channels/#{@channel.id}"} class="block">
        <figure class="aspect-video bg-base-300 flex items-center justify-center overflow-hidden">
          <img
            :if={@channel.logo_url}
            src={@channel.logo_url}
            alt={@channel.name}
            class="object-contain w-full h-full"
            loading="lazy"
          />
          <.icon
            :if={!@channel.logo_url}
            name="hero-tv"
            class="size-12 text-base-content/30"
          />
        </figure>
      </.link>
      <div class="card-body p-3">
        <h3 class="card-title text-sm truncate" title={@channel.name}>
          {@channel.name}
        </h3>
        <div class="flex justify-between items-center">
          <span :if={@channel.group_title} class="badge badge-sm badge-ghost truncate max-w-[120px]">
            {@channel.group_title}
          </span>
          <span :if={!@channel.group_title} class="badge badge-sm badge-ghost">
            Uncategorized
          </span>
          <button
            type="button"
            phx-click="toggle_favorite"
            phx-value-id={@channel.id}
            class="btn btn-ghost btn-xs btn-circle"
          >
            <.icon
              name={if @favorited, do: "hero-heart-solid", else: "hero-heart"}
              class={["size-5", @favorited && "text-error"]}
            />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a provider card for displaying IPTV providers.
  """
  attr :provider, :map, required: true

  def provider_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <div class="flex items-start justify-between">
          <div>
            <h3 class="card-title text-base">{@provider.name}</h3>
            <p class="text-sm text-base-content/60 truncate max-w-[200px]" title={@provider.url}>
              {@provider.url}
            </p>
          </div>
          <.sync_status_badge status={@provider.sync_status} />
        </div>

        <div class="flex items-center gap-4 mt-4 text-sm text-base-content/70">
          <div class="flex items-center gap-1">
            <.icon name="hero-tv" class="size-4" />
            <span>{@provider.channels_count || 0} channels</span>
          </div>
          <div :if={@provider.last_synced_at} class="flex items-center gap-1">
            <.icon name="hero-clock" class="size-4" />
            <span>Synced {format_relative_time(@provider.last_synced_at)}</span>
          </div>
        </div>

        <div class="card-actions justify-end mt-4">
          <button
            type="button"
            phx-click="sync"
            phx-value-id={@provider.id}
            class="btn btn-sm btn-ghost"
            disabled={@provider.sync_status == "syncing"}
          >
            <.icon
              name="hero-arrow-path"
              class={["size-4", @provider.sync_status == "syncing" && "animate-spin"]}
            /> Sync
          </button>
          <.link navigate={~p"/providers/#{@provider.id}/edit"} class="btn btn-sm btn-ghost">
            <.icon name="hero-pencil" class="size-4" /> Edit
          </.link>
          <button
            type="button"
            phx-click="delete"
            phx-value-id={@provider.id}
            data-confirm="Are you sure you want to delete this provider?"
            class="btn btn-sm btn-ghost text-error"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a sync status badge.
  """
  attr :status, :string, required: true

  def sync_status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @status == "idle" && "badge-ghost",
      @status == "syncing" && "badge-info",
      @status == "completed" && "badge-success",
      @status == "failed" && "badge-error"
    ]}>
      {String.capitalize(@status || "idle")}
    </span>
    """
  end

  @doc """
  Renders a history entry for watch history.
  """
  attr :entry, :map, required: true
  attr :id, :string, default: nil

  def history_entry(assigns) do
    ~H"""
    <div id={@id} class="flex items-center gap-4 py-3">
      <div class="avatar">
        <div class="w-16 h-10 rounded bg-base-300 flex items-center justify-center">
          <img
            :if={@entry.channel.logo_url}
            src={@entry.channel.logo_url}
            alt={@entry.channel.name}
            class="object-contain"
          />
          <.icon :if={!@entry.channel.logo_url} name="hero-tv" class="size-6 text-base-content/30" />
        </div>
      </div>
      <div class="flex-1 min-w-0">
        <.link
          navigate={~p"/channels/#{@entry.channel.id}"}
          class="font-medium hover:text-primary truncate block"
        >
          {@entry.channel.name}
        </.link>
        <p class="text-sm text-base-content/60">
          {format_relative_time(@entry.watched_at)}
          <span :if={@entry.duration_seconds > 0}>
            &middot; {format_duration(@entry.duration_seconds)}
          </span>
        </p>
      </div>
      <button
        type="button"
        phx-click="remove_entry"
        phx-value-id={@entry.id}
        class="btn btn-ghost btn-sm btn-circle"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  # Helper functions

  defp format_relative_time(nil), do: "Never"

  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end

  defp format_duration(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  defp format_duration(_), do: ""
end
