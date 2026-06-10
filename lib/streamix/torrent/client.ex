defmodule Streamix.Torrent.Client do
  @moduledoc """
  HTTP wrapper around the rqbit sidecar's REST API.

  rqbit (https://github.com/ikatson/rqbit) is the BitTorrent engine we
  delegate to. Streamix never speaks the BitTorrent protocol itself —
  we hand a magnet to rqbit, poll its status, and proxy the resulting
  HTTP byte range. This module is intentionally thin: every function
  is a single request to rqbit with the response decoded to a stable
  Elixir shape.

  ## Endpoint summary (rqbit 8.x)

      POST   /torrents?overwrite=true   — add a magnet, returns id + metadata
      GET    /torrents                  — list every torrent rqbit knows about
      GET    /torrents/{id}             — full details (files, peers, etc)
      GET    /torrents/{id}/stats/v1    — live progress snapshot
      DELETE /torrents/{id}             — stop and forget
      GET    /torrents/{id}/stream/{i}  — Range-aware HTTP stream of file `i`

  `id` accepts either rqbit's numeric ID or the info_hash, but we
  prefer info_hash everywhere — it's the only identifier stable across
  rqbit restarts.
  """

  require Logger

  alias Streamix.Iptv.TorrentProvider

  @default_timeout :timer.seconds(10)

  @type info_hash :: String.t()

  @type torrent_summary :: %{
          id: non_neg_integer(),
          info_hash: info_hash(),
          name: String.t() | nil,
          files: [torrent_file()]
        }

  @type torrent_file :: %{
          name: String.t(),
          length: non_neg_integer(),
          included: boolean()
        }

  @type torrent_stats :: %{
          state: String.t(),
          progress_bytes: non_neg_integer(),
          total_bytes: non_neg_integer(),
          finished: boolean(),
          live_peers: non_neg_integer(),
          download_speed_bps: non_neg_integer()
        }

  @doc """
  Adds a magnet to rqbit. `overwrite: true` makes the call idempotent —
  re-adding an existing info_hash returns the existing torrent instead
  of erroring.

  Returns `{:ok, %{info_hash, id, name, files}}` on success.
  """
  @spec add(String.t(), keyword()) :: {:ok, torrent_summary()} | {:error, term()}
  def add(magnet, opts \\ []) when is_binary(magnet) do
    overwrite = Keyword.get(opts, :overwrite, true)
    qs = if overwrite, do: "?overwrite=true", else: ""

    request(:post, "/torrents#{qs}", body: magnet, content_type: "text/plain")
    |> case do
      {:ok, %{status: 200, body: body}} ->
        {:ok, decode_summary(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current stats snapshot for a torrent. Use this to wait
  for `state == "live"` before letting the player start.
  """
  @spec stats(info_hash() | non_neg_integer()) ::
          {:ok, torrent_stats()} | {:error, term()}
  def stats(id_or_hash) do
    request(:get, "/torrents/#{id_or_hash}/stats/v1")
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, decode_stats(body)}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Detailed view: name, files (with sizes), config. Heavier than
  `stats/1`; only call when picking which file_idx to stream.
  """
  @spec details(info_hash() | non_neg_integer()) ::
          {:ok, torrent_summary()} | {:error, term()}
  def details(id_or_hash) do
    request(:get, "/torrents/#{id_or_hash}")
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, decode_summary(body)}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists every torrent rqbit currently has. Used by the reaper to find
  idle entries to drop.
  """
  @spec list() :: {:ok, [torrent_summary()]} | {:error, term()}
  def list do
    request(:get, "/torrents")
    |> case do
      {:ok, %{status: 200, body: %{"torrents" => torrents}}} when is_list(torrents) ->
        {:ok, Enum.map(torrents, &decode_summary/1)}

      {:ok, %{status: 200, body: torrents}} when is_list(torrents) ->
        {:ok, Enum.map(torrents, &decode_summary/1)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops + forgets a torrent. rqbit removes the on-disk pieces too.
  """
  @spec remove(info_hash() | non_neg_integer()) :: :ok | {:error, term()}
  def remove(id_or_hash) do
    request(:delete, "/torrents/#{id_or_hash}")
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the URL that proxies/streams file `idx` for `info_hash`,
  pointed at the *internal* rqbit endpoint. The caller (StreamController)
  is responsible for re-exposing this through Streamix's authenticated
  surface — never hand this URL to a browser directly, it bypasses
  scope checks.
  """
  @spec stream_url(info_hash() | non_neg_integer(), non_neg_integer()) :: String.t()
  def stream_url(id_or_hash, file_idx) do
    "#{base_url()}/torrents/#{id_or_hash}/stream/#{file_idx}"
  end

  @doc """
  rqbit base URL from runtime config. Resolved per-call so a config
  reload reaches us without an app restart.
  """
  def base_url do
    Keyword.fetch!(TorrentProvider.config(), :rqbit_url)
  end

  @doc """
  Shared-secret header sent on every rqbit call.

  rqbit has no native auth, so when the sidecar is reachable over a
  public hostname (e.g. a Cloudflare tunnel), a WAF/edge rule rejects
  any request missing this header. Empty list when no secret is
  configured (local/dev with rqbit on localhost) so behaviour is
  unchanged there. The web-layer stream proxy reuses this same header
  via `auth_headers/0`.
  """
  @spec auth_headers() :: [{String.t(), String.t()}]
  def auth_headers do
    case TorrentProvider.config()[:rqbit_auth_secret] do
      secret when is_binary(secret) and secret != "" -> [{"x-internal-auth", secret}]
      _ -> []
    end
  end

  # Internals

  defp request(method, path, opts \\ []) do
    url = base_url() <> path
    body = Keyword.get(opts, :body)
    content_type = Keyword.get(opts, :content_type, "application/json")
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    headers = [{"accept", "application/json"} | auth_headers()]

    headers =
      if body && content_type, do: [{"content-type", content_type} | headers], else: headers

    req_opts =
      [
        method: method,
        url: url,
        headers: headers,
        receive_timeout: timeout,
        finch: Streamix.Finch,
        decode_json: [keys: :strings]
      ]
      |> maybe_put_body(body)

    case Req.request(req_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.warning("[Torrent.Client] transport error: #{inspect(reason)}")
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_body(opts, nil), do: opts
  defp maybe_put_body(opts, body), do: Keyword.put(opts, :body, body)

  defp decode_summary(%{"details" => details} = body) do
    details
    |> decode_summary()
    |> Map.put(:id, body["id"])
  end

  defp decode_summary(body) when is_map(body) do
    %{
      id: body["id"],
      info_hash: body["info_hash"],
      name: body["name"],
      files: Enum.map(body["files"] || [], &decode_file/1)
    }
  end

  defp decode_file(%{"name" => name, "length" => length} = file) do
    %{
      name: name,
      length: length,
      included: Map.get(file, "included", true)
    }
  end

  defp decode_stats(body) when is_map(body) do
    snapshot = get_in(body, ["live", "snapshot"]) || %{}
    peer_stats = Map.get(snapshot, "peer_stats", %{})

    %{
      state: body["state"] || "unknown",
      progress_bytes: body["progress_bytes"] || 0,
      total_bytes: body["total_bytes"] || 0,
      finished: body["finished"] == true,
      live_peers: peer_stats["live"] || 0,
      download_speed_bps: get_in(snapshot, ["download_speed", "mbps"]) || 0
    }
  end
end
