defmodule Streamix.Iptv.Games.Parser do
  @moduledoc false
  alias Streamix.Iptv.Provider

  def parse(%{"data" => data} = item, provider) when is_map(data) do
    with %{"start" => start, "end" => finish} <- data["timer"],
         {:ok, starts_at} <- unix(start),
         {:ok, ends_at} <- unix(finish),
         true <- DateTime.compare(ends_at, starts_at) == :gt,
         %{"home" => home, "away" => away} when is_map(home) and is_map(away) <- data["teams"],
         league when is_binary(league) <- text(data["league"], provider),
         title when is_binary(title) <- text(item["title"], provider),
         home_name when is_binary(home_name) <- text(home["name"], provider),
         away_name when is_binary(away_name) <- text(away["name"], provider) do
      key = [league, home_name, away_name, DateTime.to_iso8601(starts_at)]

      external_key =
        :crypto.hash(:sha256, Enum.map_join(key, "\0", &String.downcase/1))
        |> Base.encode16(case: :lower)

      {:ok,
       %{
         external_key: external_key,
         league: league,
         title: title,
         home_name: home_name,
         away_name: away_name,
         home_logo_url: logo(home["image"], provider),
         away_logo_url: logo(away["image"], provider),
         starts_at: starts_at,
         ends_at: ends_at
       }, stream_ids(data["players"], provider)}
    else
      _ -> :skip
    end
  end

  def parse(_item, _provider), do: :skip

  defp unix(value) when is_integer(value), do: DateTime.from_unix(value)

  defp unix(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> unix(number)
      _ -> :error
    end
  end

  defp unix(_value), do: :error

  defp text(value, provider) when is_binary(value) do
    value = String.trim(value)

    if String.valid?(value) and byte_size(value) in 1..255 and not sensitive?(value, provider),
      do: value
  end

  defp text(_value, _provider), do: nil

  defp sensitive?(value, provider) do
    Enum.any?([provider.username, provider.password], fn secret ->
      is_binary(secret) and secret != "" and String.contains?(URI.decode(value), secret)
    end)
  end

  defp logo(value, provider) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) ->
        if not sensitive?(value, provider) and not String.contains?(value, "/live/"), do: value

      _ ->
        nil
    end
  end

  defp logo(_value, _provider), do: nil

  defp stream_ids(players, provider) when is_list(players) do
    hosts =
      provider
      |> Provider.url_chain()
      |> Enum.map(&(URI.parse(&1).host |> to_string() |> String.downcase()))

    players |> Enum.take(30) |> Enum.flat_map(&stream_id(&1, hosts, provider)) |> Enum.uniq()
  end

  defp stream_ids(_players, _provider), do: []

  defp stream_id(url, hosts, provider) when is_binary(url) do
    with {:ok, %URI{scheme: scheme, host: host, path: path, userinfo: nil}}
         when scheme in ["http", "https"] and is_binary(host) and is_binary(path) <- URI.new(url),
         true <- String.downcase(host) in hosts,
         [_, username, password, id] <- Regex.run(~r{^/live/([^/]+)/([^/]+)/(\d+)\.m3u8$}, path),
         true <-
           URI.decode(username) == provider.username and URI.decode(password) == provider.password,
         {number, ""} when number > 0 and number <= 9_223_372_036_854_775_807 <- Integer.parse(id) do
      [number]
    else
      _ -> []
    end
  end

  defp stream_id(_url, _hosts, _provider), do: []
end
