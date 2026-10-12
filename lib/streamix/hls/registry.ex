defmodule Streamix.Hls.Registry do
  @moduledoc """
  The resource graph of one HLS gateway session.

  Clients only ever see opaque identifiers. Each upstream reference a gateway
  discovers while rewriting a playlist is registered here once and keeps its
  identifier while it stays registered, so the same segment always maps to
  the same URL. There is never a caller-supplied upstream URL: a request
  names an identifier, and only a registered identifier resolves.

  A session can hold at most 20,000 resources and 4 MiB of upstream URL text;
  beyond that `register/3` refuses with `:resource_limit` instead of growing.

  ## Live sliding window

  A live playlist names new segments on every refresh, so a long-running
  channel would eventually reach those caps. With `window_seconds:` the
  registry keeps, besides the root, only resources a rewrite referenced
  within that many seconds: every registration stamps the references it
  names and first drops the ones no refresh has named for longer than the
  window. A dropped identifier no longer resolves (the player gets
  `resource_not_found` and reloads the playlist). Without a window (VOD) a
  resource stays for the life of the session.

  The identifier suffix tells the player what it is fetching. By default a
  playlist ends in `.m3u8`, a progressive root in `.mp4`, and other media in
  `.bin`; pass `:suffix` (a `fn kind, url -> suffix end`) to choose otherwise.
  """

  @max_resources 20_000
  @max_bytes 4 * 1024 * 1024

  @enforce_keys [:root, :resources, :ids, :bytes, :suffix]
  defstruct @enforce_keys ++ [window: nil, seen: %{}]

  @type kind :: :playlist | :media | :progressive
  @type t :: %__MODULE__{}

  @doc """
  Creates a registry whose root resource is `url`.

  Options: `:suffix` (see the module doc) and `:window_seconds` (enables the
  live sliding window).
  """
  @spec new(String.t(), kind(), keyword()) :: t()
  def new(url, kind, opts \\ []) when is_binary(url) do
    suffix = Keyword.get(opts, :suffix, &default_suffix/2)
    root = opaque_id() <> suffix.(kind, url)

    %__MODULE__{
      root: root,
      resources: %{root => %{url: url, kind: kind}},
      ids: %{{url, kind} => root},
      bytes: byte_size(url),
      suffix: suffix,
      window: Keyword.get(opts, :window_seconds)
    }
  end

  @doc "The root resource's identifier."
  @spec root(t()) :: String.t()
  def root(%__MODULE__{root: root}), do: root

  @doc "The upstream URL of the root resource."
  @spec root_url(t()) :: String.t()
  def root_url(%__MODULE__{root: root, resources: resources}), do: resources[root].url

  @doc "The number of registered resources, the root included."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{resources: resources}), do: map_size(resources)

  @doc "Looks up a registered resource."
  @spec lookup(t(), String.t()) :: {:ok, %{url: String.t(), kind: kind()}} | :error
  def lookup(%__MODULE__{resources: resources}, id), do: Map.fetch(resources, id)

  @doc """
  Registers `refs` (`{url, kind}` pairs) and returns one identifier per ref,
  in order. Already-registered refs keep their identifier. `now` (monotonic
  seconds) drives the live window.
  """
  @spec register(t(), [{String.t(), kind()}], integer()) ::
          {:ok, [String.t()], t()} | {:error, :resource_limit}
  def register(%__MODULE__{} = registry, refs, now \\ System.monotonic_time(:second)) do
    registry = evict(registry, now)
    new_refs = refs |> Enum.uniq() |> Enum.reject(&Map.has_key?(registry.ids, &1))
    added = Enum.sum(Enum.map(new_refs, fn {url, _kind} -> byte_size(url) end))

    if map_size(registry.resources) + length(new_refs) > @max_resources or
         registry.bytes + added > @max_bytes do
      {:error, :resource_limit}
    else
      {ids, registry} = Enum.map_reduce(refs, registry, &put/2)
      registry = %{registry | bytes: registry.bytes + added}
      {:ok, ids, stamp(registry, ids, now)}
    end
  end

  defp put({url, kind} = ref, registry) do
    case registry.ids[ref] do
      nil ->
        id = opaque_id() <> registry.suffix.(kind, url)

        {id,
         %{
           registry
           | resources: Map.put(registry.resources, id, %{url: url, kind: kind}),
             ids: Map.put(registry.ids, ref, id)
         }}

      id ->
        {id, registry}
    end
  end

  defp stamp(%__MODULE__{window: nil} = registry, _ids, _now), do: registry

  defp stamp(registry, ids, now),
    do: %{registry | seen: Enum.reduce(ids, registry.seen, &Map.put(&2, &1, now))}

  defp evict(%__MODULE__{window: nil} = registry, _now), do: registry

  defp evict(%__MODULE__{window: window} = registry, now) do
    registry.seen
    |> Enum.filter(fn {id, seen_at} -> id != registry.root and now - seen_at > window end)
    |> Enum.reduce(registry, fn {id, _seen_at}, acc -> drop(acc, id) end)
  end

  defp drop(registry, id) do
    %{url: url, kind: kind} = Map.fetch!(registry.resources, id)

    %{
      registry
      | resources: Map.delete(registry.resources, id),
        ids: Map.delete(registry.ids, {url, kind}),
        seen: Map.delete(registry.seen, id),
        bytes: registry.bytes - byte_size(url)
    }
  end

  @doc "The default identifier suffix for a resource kind."
  @spec default_suffix(kind(), String.t()) :: String.t()
  def default_suffix(:playlist, _url), do: ".m3u8"
  def default_suffix(:progressive, _url), do: ".mp4"
  def default_suffix(_kind, _url), do: ".bin"

  @doc "A fresh unguessable identifier (144 random bits, URL-safe)."
  @spec opaque_id() :: String.t()
  def opaque_id, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
end
