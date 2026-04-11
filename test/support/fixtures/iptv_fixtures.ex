defmodule Streamix.IptvFixtures do
  @moduledoc """
  Test helpers for creating IPTV entities.
  """

  alias Streamix.Iptv
  alias Streamix.Iptv.LiveChannel
  alias Streamix.Repo

  def unique_provider_name, do: "Provider #{System.unique_integer([:positive])}"
  def unique_provider_url, do: "http://provider#{System.unique_integer([:positive])}.example.com"

  def valid_provider_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_provider_name(),
      url: unique_provider_url(),
      username: "testuser",
      password: "testpass"
    })
  end

  def provider_fixture(user, attrs \\ %{}) do
    attrs =
      attrs
      |> valid_provider_attrs()

    {:ok, provider} = Iptv.create_provider(user.id, attrs)
    provider
  end

  def valid_channel_attrs(provider, attrs \\ %{}) do
    Enum.into(attrs, %{
      stream_id: System.unique_integer([:positive]),
      name: "Channel #{System.unique_integer([:positive])}",
      stream_icon: "http://example.com/logo.png",
      epg_channel_id: "ch#{System.unique_integer([:positive])}",
      tv_archive: false,
      provider_id: provider.id
    })
  end

  def channel_fixture(provider, attrs \\ %{}) do
    attrs = valid_channel_attrs(provider, attrs)

    %LiveChannel{}
    |> LiveChannel.changeset(attrs)
    |> Repo.insert!()
  end

  def channels_fixture(provider, count, attrs \\ %{}) do
    Enum.map(1..count, fn i ->
      channel_fixture(provider, Map.merge(attrs, %{name: "Channel #{i}"}))
    end)
  end

  def favorite_fixture(user, channel) do
    {:ok, favorite} =
      Iptv.add_favorite(user.id, %{
        content_type: "live_channel",
        content_id: channel.id,
        content_name: channel.name,
        content_icon: channel.stream_icon
      })

    favorite
  end

  def watch_history_fixture(user, channel, duration \\ 0) do
    {:ok, history} =
      Iptv.add_watch_history(user.id, "live_channel", channel.id, %{
        content_name: channel.name,
        content_icon: channel.stream_icon,
        duration_seconds: duration
      })

    history
  end

  def valid_epg_program_attrs(provider, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    start_time = Map.get(attrs, :start_time, DateTime.add(now, -30, :minute))
    end_time = Map.get(attrs, :end_time, DateTime.add(now, 30, :minute))

    Enum.into(attrs, %{
      epg_channel_id: "ch#{System.unique_integer([:positive])}",
      title: "Program #{System.unique_integer([:positive])}",
      description: "Test program description",
      start_time: start_time,
      end_time: end_time,
      category: "Entertainment",
      lang: "pt",
      provider_id: provider.id
    })
  end

  def epg_program_fixture(provider, attrs \\ %{}) do
    alias Streamix.Iptv.EpgProgram

    attrs = valid_epg_program_attrs(provider, attrs)

    %EpgProgram{}
    |> EpgProgram.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Creates a complete test setup with user, provider, and channels.
  Returns a map with :user, :provider, and :channels.
  """
  def full_setup(user, channel_count \\ 5) do
    provider = provider_fixture(user)
    channels = channels_fixture(provider, channel_count)

    %{
      user: user,
      provider: provider,
      channels: channels
    }
  end

  @doc """
  Sample M3U content for parser tests.
  """
  def sample_m3u_content do
    """
    #EXTM3U
    #EXTINF:-1 tvg-id="ch1" tvg-name="Channel One" tvg-logo="http://logo.com/1.png" group-title="News",Channel 1
    http://stream.example.com/1.ts
    #EXTINF:-1 tvg-id="ch2" tvg-name="Channel Two" tvg-logo="http://logo.com/2.png" group-title="Sports",Channel 2
    http://stream.example.com/2.ts
    #EXTINF:-1 tvg-id="ch3" group-title="Movies",Channel 3
    http://stream.example.com/3.ts
    """
  end

  def sample_m3u_channels do
    [
      %{
        name: "Channel 1",
        stream_url: "http://stream.example.com/1.ts",
        logo_url: "http://logo.com/1.png",
        tvg_id: "ch1",
        tvg_name: "Channel One",
        group_title: "News"
      },
      %{
        name: "Channel 2",
        stream_url: "http://stream.example.com/2.ts",
        logo_url: "http://logo.com/2.png",
        tvg_id: "ch2",
        tvg_name: "Channel Two",
        group_title: "Sports"
      },
      %{
        name: "Channel 3",
        stream_url: "http://stream.example.com/3.ts",
        logo_url: nil,
        tvg_id: "ch3",
        tvg_name: nil,
        group_title: "Movies"
      }
    ]
  end

  def valid_movie_attrs(provider, attrs \\ %{}) do
    Enum.into(attrs, %{
      stream_id: System.unique_integer([:positive]),
      name: "Movie #{System.unique_integer([:positive])}",
      title: "Movie Title #{System.unique_integer([:positive])}",
      year: 2023,
      container_extension: "mp4",
      provider_id: provider.id,
      rating: Decimal.new("8.5"),
      added: DateTime.utc_now()
    })
  end

  def movie_fixture(provider, attrs \\ %{}) do
    alias Streamix.Iptv.Movie

    attrs = valid_movie_attrs(provider, attrs)

    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert!()
  end

  def valid_series_attrs(provider, attrs \\ %{}) do
    Enum.into(attrs, %{
      series_id: System.unique_integer([:positive]),
      name: "Series #{System.unique_integer([:positive])}",
      title: "Series Title #{System.unique_integer([:positive])}",
      year: 2023,
      provider_id: provider.id,
      rating: Decimal.new("8.1")
    })
  end

  def series_content_fixture(provider, attrs \\ %{}) do
    alias Streamix.Iptv.Series

    attrs = valid_series_attrs(provider, attrs)

    %Series{}
    |> Series.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Creates a favorite for a movie.
  """
  def movie_favorite_fixture(user, movie) do
    {:ok, favorite} =
      Iptv.add_favorite(user.id, %{
        content_type: "movie",
        content_id: movie.id
      })

    favorite
  end

  @doc """
  Creates a watch history entry for a movie.
  """
  def movie_history_fixture(user, movie, attrs \\ %{}) do
    duration = Map.get(attrs, :duration_seconds, 7200)
    progress = Map.get(attrs, :progress_seconds, 0)

    {:ok, history} =
      Iptv.add_watch_history(user.id, "movie", movie.id, %{
        duration_seconds: duration,
        progress_seconds: progress
      })

    history
  end
end
