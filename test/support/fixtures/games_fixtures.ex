defmodule Streamix.GamesFixtures do
  @moduledoc false

  def game_fixture(provider, channel, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    defaults = %{
      provider_id: provider.id,
      live_channel_id: channel && channel.id,
      external_key: "game-#{System.unique_integer([:positive])}",
      league: "Brasileirão",
      title: "Home vs Away",
      home_name: "Home",
      away_name: "Away",
      home_logo_url: "https://images.example.com/home.png",
      away_logo_url: "https://images.example.com/away.png",
      starts_at: DateTime.add(now, -1800),
      ends_at: DateTime.add(now, 1800)
    }

    struct(Streamix.Iptv.SportsMatch, Map.merge(defaults, attrs)) |> Streamix.Repo.insert!()
  end

  def game_payload(provider, stream_id, starts_at, ends_at) do
    %{
      "title" => "Monza vs Cagliari",
      "data" => %{
        "league" => "Campeonato Italiano",
        "timer" => %{
          "day" => "19102026",
          "start" => to_string(DateTime.to_unix(starts_at)),
          "end" => to_string(DateTime.to_unix(ends_at))
        },
        "teams" => %{
          "home" => %{"name" => "Monza", "image" => "https://images.example.com/home.png"},
          "away" => %{"name" => "Cagliari", "image" => "https://images.example.com/away.png"}
        },
        "players" => [
          "#{provider.url}/live/#{provider.username}/#{provider.password}/#{stream_id}.m3u8"
        ]
      }
    }
  end
end
