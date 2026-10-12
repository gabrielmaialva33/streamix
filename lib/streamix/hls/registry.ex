defmodule Streamix.Hls.Registry do
  @moduledoc """
  The resource graph of one HLS gateway session.

  Clients only ever see opaque identifiers. Each upstream reference a gateway
  discovers while rewriting a playlist is registered here once and keeps its
  identifier for the life of the session, so the same segment always maps to
  the same URL. There is never a caller-supplied upstream URL: a request
  names an identifier, and only a registered identifier resolves.

  A session can hold at most 20,000 resources and 4 MiB of upstream URL text;
  beyond that `register/2` refuses with `:resource_limit` instead of growing.

  The identifier suffix tells the player what it is fetching. By default a
  playlist ends in `.m3u8`, a progressive root in `.mp4`, and other media in
  `.bin`; pass `:suffix` (a `fn kind, url -> suffix end`) to choose otherwise.
  """

  @max_resources 20_000
  @max_bytes 4 * 1024 * 1024

  @enforce_keys [:root, :resources, :ids, :bytes, :suffix]
  defstruct @enforce_keys

  @type kind :: :playlist | :media | :progressive
  @type t :: %__MODULE__{}

  @doc "Creates a registry whose root resource is `url`."
  @spec new(String.t(), kind(), keyword()) :: t()
  def new(url, kind, opts \\ []) when is_binary(url) do
    suffix = Keyword.get(opts, :suffix, &default_suffix/2)
    root = opaque_id() <> suffix.(kind, url)

    %__MODULE__{
      root: root,
      resources: %{root => %{url: url, kind: kind}},
      ids: %{{url, kind} => root},
      bytes: byte_size(url),
      suffix: suffix
    }
  end

  @doc "The root resource's identifier."
  @spec root(t()) :: String.t()
  def root(%__MODULE__{root: root}), do: root

  @doc "The upstream URL of the root resource."
  @spec root_url(t()) :: String.t()
  def root_url(%__MODULE__{root: root, resources: resources}), do: resources[root].url

  @doc "Looks up a registered resource."
  @spec lookup(t(), String.t()) :: {:ok, %{url: String.t(), kind: kind()}} | :error
  def lookup(%__MODULE__{resources: resources}, id), do: Map.fetch(resources, id)

  @doc """
  Registers `refs` (`{url, kind}` pairs) and returns one identifier per ref,
  in order. Already-registered refs keep their identifier.
  """
  @spec register(t(), [{String.t(), kind()}]) ::
          {:ok, [String.t()], t()} | {:error, :resource_limit}
  def register(%__MODULE__{} = registry, refs) do
    new_refs = refs |> Enum.uniq() |> Enum.reject(&Map.has_key?(registry.ids, &1))
    added = Enum.sum(Enum.map(new_refs, fn {url, _kind} -> byte_size(url) end))

    if map_size(registry.resources) + length(new_refs) > @max_resources or
         registry.bytes + added > @max_bytes do
      {:error, :resource_limit}
    else
      {ids, registry} = Enum.map_reduce(refs, registry, &put/2)
      {:ok, ids, %{registry | bytes: registry.bytes + added}}
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

  @doc "The default identifier suffix for a resource kind."
  @spec default_suffix(kind(), String.t()) :: String.t()
  def default_suffix(:playlist, _url), do: ".m3u8"
  def default_suffix(:progressive, _url), do: ".mp4"
  def default_suffix(_kind, _url), do: ".bin"

  @doc "A fresh unguessable identifier (144 random bits, URL-safe)."
  @spec opaque_id() :: String.t()
  def opaque_id, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
end
