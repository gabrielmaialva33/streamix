defmodule Streamix.Embedplay.Gateway do
  @moduledoc false

  alias Streamix.Embedplay
  alias Streamix.Embedplay.{HLS, HTTP, Sessions}

  @media_types ~w(video/mp2t video/mp4 audio/mp4 audio/aac audio/mpeg text/vtt application/octet-stream)

  def fetch_resource(sid, rid, movie_id, opts \\ []) do
    with true <- Embedplay.enabled?(),
         :ok <- valid_range(Keyword.get(opts, :range)),
         {:ok, resource} <- Sessions.resource(sid, rid, movie_id),
         {:ok, lease} <- Sessions.acquire() do
      try do
        fetch(resource, sid, movie_id, opts)
      after
        Sessions.release(lease)
      end
    else
      false -> {:error, :provider_disabled}
      error -> error
    end
  end

  def rewrite_playlist(body, base_url, sid, movie_id, resource_url) do
    with {:ok, nodes} <- HLS.parse(body, base_url),
         resources = for({:resource, url, kind} <- nodes, do: {url, kind}),
         {:ok, ids} <- Sessions.register(sid, movie_id, Enum.uniq(resources)) do
      mapping = Map.new(Enum.zip(Enum.uniq(resources), ids))

      rewritten =
        Enum.map(nodes, fn
          {:resource, url, kind} -> resource_url.(sid, Map.fetch!(mapping, {url, kind}))
          text -> text
        end)

      {:ok, IO.iodata_to_binary(rewritten)}
    end
  end

  defp fetch(resource, sid, movie_id, opts) do
    if resource.kind == :playlist and Keyword.get(opts, :method) == :head do
      manifest_head()
    else
      fetch_opts =
        if resource.kind == :playlist, do: [], else: Keyword.take(opts, [:range, :method])

      case HTTP.fetch(resource.url, resource.headers, fetch_opts) do
        {:ok, response} ->
          prepare_response(response, resource, sid, movie_id, opts)

        {:error, :playback_restart_required} = error ->
          Sessions.invalidate(sid)
          error

        error ->
          error
      end
    end
  end

  defp prepare_response(response, resource, sid, movie_id, opts) do
    if resource.kind == :playlist or HLS.playlist?(response.body) do
      with {:ok, body} <-
             rewrite_playlist(
               response.body,
               response.url,
               sid,
               movie_id,
               Keyword.fetch!(opts, :resource_url)
             ) do
        {:ok,
         %{
           status: 200,
           body: body,
           headers: %{"content-type" => ["application/vnd.apple.mpegurl"]}
         }}
      end
    else
      headers = Map.put(response.headers, "content-type", [media_type(response.headers)])
      {:ok, %{status: response.status, body: response.body, headers: headers}}
    end
  end

  # Upstream content types are advisory. Anything outside the allowlist — a
  # missing header, a parameterized type, or HTML pretending to be a segment —
  # collapses to an opaque download so the browser never interprets it.
  defp media_type(headers) do
    declared =
      case headers |> Map.get("content-type", []) |> List.first() do
        type when is_binary(type) -> type |> String.split(";") |> hd() |> String.downcase()
        _ -> nil
      end

    if declared in @media_types, do: declared, else: "application/octet-stream"
  end

  defp manifest_head do
    {:ok,
     %{status: 200, body: "", headers: %{"content-type" => ["application/vnd.apple.mpegurl"]}}}
  end

  defp valid_range(nil), do: :ok

  defp valid_range(range) when is_binary(range) and byte_size(range) <= 80 do
    if Regex.match?(~r/^bytes=(?:\d+-\d*|-\d+)$/, range),
      do: :ok,
      else: {:error, :invalid_range}
  end

  defp valid_range(_), do: {:error, :invalid_range}
end
