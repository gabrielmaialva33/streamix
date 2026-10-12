defmodule Streamix.Torrent.Sources.PostParser do
  @moduledoc """
  Extracts release data from one BR torrent post (detail page).

  Pure: takes a parsed document plus the mirror profile from
  `Streamix.Torrent.Sources.ScraperSite` and returns the raw title, the
  original title, year, IMDb id, poster and every magnet together with the
  text that describes it.

  Magnets are collected in document order. Each one keeps:

    * `label` — the text between the previous magnet (or heading) and this
      one, plus the link's own text. On ComandoTorrent that is
      `"WEB-DL 2160p 4K (MKV) | 19.19 GB"`, on GratisTorrent the button
      text `"DOWNLOAD TORRENT LEGENDADO 5.1 MKV 2160P"`.
    * `section` — the closest heading before it (`":: LEGENDADO ::"`).
    * `display_name` — the magnet's own `dn=` name.

  so the audio of each file can be resolved individually instead of
  stamping the post title's "Dual Áudio" on a subtitled 4K file.
  """

  alias Streamix.Torrent.Magnet
  alias Streamix.Torrent.Sources.ReleaseInfo

  @imdb_url ~r/imdb\.com\/(?:[a-z]{2}(?:-[a-z]{2})?\/)?title\/(tt\d{5,10})/i
  @max_label_chars 300

  @type magnet :: %{
          uri: String.t(),
          info_hash: String.t() | nil,
          display_name: String.t() | nil,
          label: String.t(),
          section: String.t()
        }

  @type t :: %{
          raw_title: String.t(),
          original_title: String.t() | nil,
          year: integer() | nil,
          imdb_id: String.t() | nil,
          poster_url: String.t() | nil,
          magnets: [magnet()]
        }

  @doc "Parses a detail page with the given mirror profile."
  @spec parse(Floki.html_tree(), map()) :: t()
  def parse(doc, mirror) do
    scope = scope(doc, Map.get(mirror, :content_selector))
    json_ld = json_ld(doc)
    raw_title = raw_title(doc, Map.get(mirror, :title_selector))
    info_lines = info_lines(scope)

    %{
      raw_title: raw_title,
      original_title: original_title(doc, mirror, info_lines, json_ld),
      year: year(raw_title, info_lines, json_ld),
      imdb_id: imdb_id(doc, mirror, json_ld),
      poster_url: poster_url(doc, Map.get(mirror, :poster_selector)),
      magnets: magnets(scope)
    }
  end

  @doc """
  Every magnet in `nodes`, in document order, with its label and section.
  """
  @spec magnets(Floki.html_tree() | Floki.html_node()) :: [magnet()]
  def magnets(nodes) do
    {_state, acc} = walk(List.wrap(nodes), %{section: "", pending: ""}, [])

    acc
    |> Enum.reverse()
    |> Enum.uniq_by(&(&1.info_hash || &1.uri))
  end

  @doc "First IMDb title id (`tt…`) found in the given URLs, or nil."
  @spec imdb_from_urls([String.t()]) :: String.t() | nil
  def imdb_from_urls(urls) do
    Enum.find_value(urls, fn url ->
      case Regex.run(@imdb_url, url, capture: :all_but_first) do
        [id] -> String.downcase(id)
        _ -> nil
      end
    end)
  end

  # --- title / year / ids --------------------------------------------------

  defp raw_title(doc, selector) do
    [selector, "h1", "title"]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value("", fn sel -> first_text(doc, sel) end)
  end

  defp original_title(doc, mirror, info_lines, json_ld) do
    from_selector =
      case Map.get(mirror, :original_title_selector) do
        nil -> nil
        selector -> first_text(doc, selector)
      end

    candidate =
      from_selector ||
        info_value(info_lines, ~r/^t[íi]tulo\s+original\s*:\s*(.+)$/iu) ||
        json_ld_value(json_ld, "alternateName")

    case candidate && ReleaseInfo.extract_title(candidate) do
      nil -> nil
      "" -> nil
      title -> title
    end
  end

  defp year(raw_title, info_lines, json_ld) do
    ReleaseInfo.extract_year(raw_title) ||
      info_year(info_lines) ||
      json_ld |> json_ld_value("copyrightYear") |> to_year()
  end

  defp info_year(lines) do
    lines
    |> info_value(~r/^(?:ano\s+de\s+)?lan[çc]amento\s*:\s*((?:19|20)\d{2})\b/iu)
    |> to_year()
  end

  defp to_year(nil), do: nil
  defp to_year(year) when is_integer(year), do: year

  defp to_year(year) when is_binary(year) do
    case Integer.parse(String.trim(year)) do
      {value, _rest} when value in 1900..2100 -> value
      _ -> nil
    end
  end

  defp imdb_id(doc, mirror, json_ld) do
    json_ld_imdb(json_ld) ||
      doc
      |> Floki.find(Map.get(mirror, :imdb_selector) || "a[href*='imdb.com']")
      |> Floki.attribute("href")
      |> imdb_from_urls()
  end

  defp json_ld_imdb(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      List.wrap(entry["sameAs"]) ++ List.wrap(entry["url"])
    end)
    |> Enum.filter(&is_binary/1)
    |> imdb_from_urls()
  end

  defp poster_url(_doc, nil), do: nil

  defp poster_url(doc, selector) do
    doc
    |> Floki.find(selector)
    |> Enum.flat_map(fn node ->
      Floki.attribute([node], "src") ++ Floki.attribute([node], "data-src")
    end)
    |> Enum.find(&String.starts_with?(&1, "http"))
  end

  # --- JSON-LD ---------------------------------------------------------------

  defp json_ld(doc) do
    doc
    |> Floki.find("script[type='application/ld+json']")
    |> Enum.flat_map(fn {_tag, _attrs, children} ->
      children
      |> Enum.filter(&is_binary/1)
      |> Enum.join()
      |> decode_json_ld()
    end)
  end

  defp decode_json_ld(text) do
    case Jason.decode(text) do
      {:ok, %{"@graph" => graph}} when is_list(graph) -> Enum.filter(graph, &is_map/1)
      {:ok, entry} when is_map(entry) -> [entry]
      {:ok, entries} when is_list(entries) -> Enum.filter(entries, &is_map/1)
      _ -> []
    end
  end

  defp json_ld_value(entries, key) do
    entries
    |> Enum.filter(&(&1["@type"] in ["Movie", "TVSeries", "VideoObject", "CreativeWork"]))
    |> Enum.find_value(fn entry ->
      case entry[key] do
        value when is_binary(value) and value != "" -> value
        value when is_integer(value) -> value
        _ -> nil
      end
    end)
  end

  # --- info block ("Título Original: …", "Lançamento: 2024") -----------------

  defp info_lines(scope) do
    scope
    |> List.wrap()
    |> Floki.raw_html()
    |> String.replace(~r/<br\s*\/?>|<\/p>|<\/div>|<\/li>|<\/h\d>/iu, "\n")
    |> Floki.parse_fragment()
    |> case do
      {:ok, nodes} -> Floki.text(nodes)
      _ -> ""
    end
    |> String.split("\n")
    |> Enum.map(&squish/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp info_value(lines, regex) do
    Enum.find_value(lines, fn line ->
      case Regex.run(regex, line, capture: :all_but_first) do
        [value | _] -> blank_to_nil(squish(value))
        _ -> nil
      end
    end)
  end

  # --- magnets --------------------------------------------------------------

  defp walk([], state, acc), do: {state, acc}

  defp walk([node | rest], state, acc) do
    {state, acc} = visit(node, state, acc)
    walk(rest, state, acc)
  end

  defp visit(text, state, acc) when is_binary(text), do: {append(state, text), acc}

  defp visit({tag, _attrs, _children}, state, acc)
       when tag in ["script", "style", "noscript", "template"],
       do: {state, acc}

  defp visit({tag, _attrs, children}, state, acc)
       when tag in ["h1", "h2", "h3", "h4", "h5", "h6"] do
    {%{state | section: squish(Floki.text(children)), pending: ""}, acc}
  end

  defp visit({"a", attrs, children}, state, acc) do
    case attr(attrs, "href") do
      "magnet:" <> _ = uri ->
        label = squish(state.pending <> " " <> Floki.text(children))
        {%{state | pending: ""}, [magnet_entry(uri, label, state.section) | acc]}

      _ ->
        walk(children, state, acc)
    end
  end

  defp visit({_tag, _attrs, children}, state, acc) when is_list(children),
    do: walk(children, state, acc)

  defp visit(_node, state, acc), do: {state, acc}

  defp magnet_entry(uri, label, section) do
    %{
      uri: uri,
      info_hash: Magnet.info_hash(uri),
      display_name: display_name(uri),
      label: label,
      section: section
    }
  end

  # A malformed percent-escape in `dn=` must not take the whole post down.
  defp display_name(uri) do
    Magnet.display_name(uri)
  rescue
    ArgumentError -> nil
  end

  defp append(state, text) do
    pending = state.pending <> " " <> text
    length = String.length(pending)

    pending =
      if length > @max_label_chars,
        do: String.slice(pending, length - @max_label_chars, @max_label_chars),
        else: pending

    %{state | pending: pending}
  end

  # --- helpers --------------------------------------------------------------

  defp scope(doc, nil), do: doc

  defp scope(doc, selector) do
    case Floki.find(doc, selector) do
      [] -> doc
      nodes -> nodes
    end
  end

  defp first_text(doc, selector) do
    doc
    |> Floki.find(selector)
    |> Enum.find_value(fn node -> blank_to_nil(squish(Floki.text([node]))) end)
  end

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp squish(text) when is_binary(text) do
    text |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
