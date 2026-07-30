defmodule Streamix.TvAppRelease do
  @moduledoc """
  Looks up the latest `streamix-tv` release from GitHub so `/tv` always
  shows the most recent APK / WGT instead of whatever was hardcoded at
  build time. Cached for an hour in `Streamix.Cache` so the page render
  doesn't hit GitHub on every mount.

  Falls back to the compile-time defaults from `:streamix, :tv_app` if
  GitHub is unreachable, rate-limits, or the response is malformed —
  the /tv page still renders, just stale.
  """

  require Logger

  alias Streamix.Cache

  @cache_key "tv_app:release:latest"
  @cache_ttl 3_600
  @repo "gabrielmaialva33/streamix-tv"
  @api_url "https://api.github.com/repos/#{@repo}/releases/latest"

  @type info :: %{
          release_tag: String.t(),
          release_url: String.t(),
          apk_short_url: String.t(),
          apk_size_mb: String.t(),
          apk_sha256: String.t(),
          wgt_short_url: String.t(),
          wgt_size_mb: String.t(),
          wgt_sha256: String.t()
        }

  @doc """
  Returns the latest release metadata, falling back to the configured
  defaults on any failure.
  """
  @spec latest() :: info()
  def latest do
    Cache.fetch(@cache_key, @cache_ttl, &fetch_latest/0)
  end

  defp fetch_latest do
    case Req.get(@api_url,
           receive_timeout: 5_000,
           finch: [name: Streamix.Finch],
           headers: [
             {"accept", "application/vnd.github+json"},
             {"user-agent", "streamix.mahina.cloud"}
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        merge_into_defaults(body)

      {:ok, %{status: status}} ->
        Logger.warning("[TvAppRelease] GitHub returned #{status}, using configured defaults")
        defaults()

      {:error, reason} ->
        Logger.warning("[TvAppRelease] GitHub fetch failed: #{inspect(reason)}")
        defaults()
    end
  end

  defp merge_into_defaults(%{"tag_name" => tag, "html_url" => html_url, "assets" => assets})
       when is_list(assets) do
    apk = find_asset(assets, ".apk")
    wgt = find_asset(assets, ".wgt")

    defaults()
    |> Map.put(:release_tag, tag)
    |> Map.put(:release_url, html_url)
    |> maybe_put_asset(:apk_short_url, apk["browser_download_url"])
    |> maybe_put_asset(:apk_size_mb, asset_mb(apk))
    |> maybe_put_asset(:apk_sha256, asset_digest(apk))
    |> maybe_put_asset(:wgt_short_url, wgt["browser_download_url"])
    |> maybe_put_asset(:wgt_size_mb, asset_mb(wgt))
    |> maybe_put_asset(:wgt_sha256, asset_digest(wgt))
  end

  defp merge_into_defaults(_body), do: defaults()

  defp find_asset(assets, suffix) do
    Enum.find(assets, %{}, fn asset ->
      name = Map.get(asset, "name", "")
      is_binary(name) and String.ends_with?(name, suffix)
    end)
  end

  defp asset_mb(%{"size" => bytes}) when is_integer(bytes) do
    (bytes / (1024 * 1024))
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp asset_mb(_), do: nil

  defp asset_digest(%{"digest" => "sha256:" <> hex}), do: hex
  defp asset_digest(_), do: nil

  defp maybe_put_asset(map, _key, nil), do: map
  defp maybe_put_asset(map, key, value), do: Map.put(map, key, value)

  defp defaults do
    cfg = Application.get_env(:streamix, :tv_app, [])
    Map.new(cfg)
  end
end
