defmodule Streamix.IptvFixtures do
  @moduledoc """
  Test helpers for creating IPTV entities.
  """

  alias Streamix.Iptv
  alias Streamix.Iptv.Channel
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
      |> Map.put(:user_id, user.id)

    {:ok, provider} = Iptv.create_provider(attrs)
    provider
  end

  def valid_channel_attrs(provider, attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Channel #{System.unique_integer([:positive])}",
      stream_url: "http://stream.example.com/#{System.unique_integer([:positive])}.ts",
      logo_url: "http://example.com/logo.png",
      tvg_id: "ch#{System.unique_integer([:positive])}",
      tvg_name: "Test Channel",
      group_title: "General",
      provider_id: provider.id
    })
  end

  def channel_fixture(provider, attrs \\ %{}) do
    attrs = valid_channel_attrs(provider, attrs)

    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert!()
  end

  def channels_fixture(provider, count, attrs \\ %{}) do
    Enum.map(1..count, fn i ->
      channel_fixture(provider, Map.merge(attrs, %{name: "Channel #{i}"}))
    end)
  end

  def favorite_fixture(user, channel) do
    {:ok, favorite} = Iptv.add_favorite(user.id, channel.id)
    favorite
  end

  def watch_history_fixture(user, channel, duration \\ 0) do
    {:ok, history} = Iptv.add_watch_history(user.id, channel.id, duration)
    history
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
end
