defmodule Streamix.Iptv.EpgParser do
  @moduledoc """
  Parser for EPG data from Xtream Codes API.

  Two formats are supported:

  * **`get_short_epg`** JSON response — base64-encoded fields, used for
    on-demand single-channel queries.
  * **XMLTV** (returned by `/xmltv.php`) — single document covering the
    full catalog. Used by `SyncEpgWorker`.
  """

  require Logger

  @doc """
  Parses the short EPG API response (get_short_epg action).
  Returns a list of program maps ready for database insertion.

  ## Example Response Structure
      %{
        "epg_listings" => [
          %{
            "id" => "12345",
            "channel_id" => "ch1",
            "title" => "base64_encoded_title",
            "description" => "base64_encoded_description",
            "start" => "2024-01-01 10:00:00",
            "end" => "2024-01-01 11:00:00",
            "start_timestamp" => 1704103200,
            "stop_timestamp" => 1704106800,
            "lang" => "en"
          }
        ]
      }
  """
  def parse_short_epg(%{"epg_listings" => listings}) when is_list(listings) do
    programs =
      listings
      |> Enum.map(&parse_listing/1)
      |> Enum.filter(&valid_program?/1)

    {:ok, programs}
  end

  def parse_short_epg(_), do: {:ok, []}

  @doc """
  Parses an XMLTV document (the format `/xmltv.php` returns).

  Returns `{:ok, %{channel_external_id => [program_map, ...]}}` keyed by
  the `channel` attribute on each `<programme>` element. The map shape
  matches what `EpgSync.upsert_programs/1` expects, except that
  `:epg_channel_id` is left blank — caller resolves that from
  `channel_external_id` against the local `epg_channels` table.

  ## XMLTV format reference

      <tv>
        <channel id="globortv.br">
          <display-name>Globo RTV</display-name>
        </channel>
        <programme channel="globortv.br"
                   start="20260503040000 -0300"
                   stop="20260503050000 -0300">
          <title>Some show</title>
          <desc>Description</desc>
          <category>Drama</category>
        </programme>
      </tv>
  """
  def parse_xmltv(xml) when is_binary(xml) do
    # Saxy SAX parser. XMLTV from Choki is ~14 MB. SweetXml (DOM via
    # xmerl) consumed 1.4 GB and 100% CPU on the parse tree alone.
    # OTP's `:xmerl_sax_parser` is a SAX option but the API is brittle
    # and slower than Saxy. Saxy benchmarks ~4.5x faster than xmerl
    # with ~10x less memory, and is a pure-Elixir streaming parser.
    initial = %{programmes: [], current: nil, char_buf: nil}

    case Saxy.parse_string(xml, __MODULE__.XmltvHandler, initial) do
      {:ok, %{programmes: list}} ->
        grouped =
          list
          |> Enum.reverse()
          |> Enum.filter(&valid_program?/1)
          |> Enum.group_by(& &1.channel_external_id)

        {:ok, grouped}

      {:error, reason} ->
        {:error, {:xmltv_parse_failed, reason}}
    end
  rescue
    e -> {:error, {:xmltv_parse_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:xmltv_parse_failed, reason}}
  end

  defmodule XmltvHandler do
    @moduledoc false
    @behaviour Saxy.Handler

    alias Streamix.Iptv.EpgParser

    @impl true
    def handle_event(:start_document, _prolog, state), do: {:ok, state}

    @impl true
    def handle_event(:end_document, _data, state), do: {:ok, state}

    @impl true
    def handle_event(:start_element, {"programme", attrs}, state) do
      programme = %{
        channel_external_id: attr(attrs, "channel"),
        start_time: attrs |> attr("start") |> EpgParser.public_parse_xmltv_datetime(),
        end_time: attrs |> attr("stop") |> EpgParser.public_parse_xmltv_datetime()
      }

      {:ok, %{state | current: programme, char_buf: nil}}
    end

    def handle_event(:start_element, {name, attrs}, %{current: cur} = state)
        when not is_nil(cur) do
      case name do
        "icon" ->
          {:ok, %{state | current: Map.put(cur, :icon, attr(attrs, "src")), char_buf: nil}}

        "title" ->
          # XMLTV often has <title> and <sub-title>; keep only the first.
          cur =
            if Map.has_key?(cur, :lang), do: cur, else: Map.put(cur, :lang, attr(attrs, "lang"))

          {:ok, %{state | current: cur, char_buf: []}}

        n when n in ["desc", "category"] ->
          {:ok, %{state | char_buf: []}}

        _ ->
          {:ok, %{state | char_buf: nil}}
      end
    end

    def handle_event(:start_element, _, state), do: {:ok, state}

    @impl true
    def handle_event(:characters, chars, %{char_buf: buf} = state) when is_list(buf) do
      {:ok, %{state | char_buf: [chars | buf]}}
    end

    def handle_event(:characters, _chars, state), do: {:ok, state}

    @impl true
    def handle_event(:end_element, "programme", %{current: cur} = state) when not is_nil(cur) do
      {:ok, %{state | programmes: [cur | state.programmes], current: nil, char_buf: nil}}
    end

    def handle_event(:end_element, name, %{current: cur, char_buf: buf} = state)
        when not is_nil(cur) and is_list(buf) do
      key =
        case name do
          "title" -> :title
          "desc" -> :description
          "category" -> :category
          _ -> nil
        end

      cur = if key, do: Map.put_new(cur, key, flush_buf(buf)), else: cur
      {:ok, %{state | current: cur, char_buf: nil}}
    end

    def handle_event(:end_element, _name, state), do: {:ok, %{state | char_buf: nil}}

    @impl true
    def handle_event(:cdata, chars, %{char_buf: buf} = state) when is_list(buf) do
      {:ok, %{state | char_buf: [chars | buf]}}
    end

    def handle_event(:cdata, _chars, state), do: {:ok, state}

    defp attr(attrs, key) do
      case Enum.find(attrs, fn {k, _v} -> k == key end) do
        {_, v} -> v
        _ -> nil
      end
    end

    defp flush_buf(buf) do
      buf
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> String.trim()
      |> case do
        "" -> nil
        s -> s
      end
    end
  end

  # Public wrapper so the SAX handler module (which can't import private
  # functions) can hit the datetime parser.
  @doc false
  def public_parse_xmltv_datetime(s), do: parse_xmltv_datetime(s)

  # XMLTV datetime: "20260503040000 -0300" or "20260503040000"
  defp parse_xmltv_datetime(nil), do: nil
  defp parse_xmltv_datetime(""), do: nil

  defp parse_xmltv_datetime(str) when is_binary(str) do
    case Regex.run(
           ~r/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-])(\d{2})(\d{2}))?$/,
           String.trim(str)
         ) do
      [_, y, mo, d, h, mi, s] ->
        build_dt(%{y: y, mo: mo, d: d, h: h, mi: mi, s: s, sign: "+", oh: "00", om: "00"})

      [_, y, mo, d, h, mi, s, sign, oh, om] ->
        build_dt(%{y: y, mo: mo, d: d, h: h, mi: mi, s: s, sign: sign, oh: oh, om: om})

      _ ->
        nil
    end
  end

  defp build_dt(%{y: y, mo: mo, d: d, h: h, mi: mi, s: s, sign: sign, oh: oh, om: om}) do
    case NaiveDateTime.new(
           String.to_integer(y),
           String.to_integer(mo),
           String.to_integer(d),
           String.to_integer(h),
           String.to_integer(mi),
           String.to_integer(s)
         ) do
      {:ok, naive} ->
        offset_seconds =
          (String.to_integer(oh) * 3600 + String.to_integer(om) * 60) * sign_multiplier(sign)

        # Local time in XMLTV → convert to UTC by subtracting the offset.
        naive
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.add(-offset_seconds, :second)

      _ ->
        nil
    end
  end

  defp sign_multiplier("-"), do: -1
  defp sign_multiplier(_), do: 1

  defp parse_listing(item) when is_map(item) do
    %{
      epg_channel_id: to_string(item["channel_id"] || item["epg_id"]),
      title: decode_base64_field(item["title"]),
      description: decode_base64_field(item["description"]),
      start_time: parse_timestamp(item["start_timestamp"], item["start"]),
      end_time: parse_timestamp(item["stop_timestamp"], item["end"]),
      category: item["category"],
      icon: item["icon"],
      lang: item["lang"]
    }
  end

  defp parse_listing(_), do: nil

  defp valid_program?(nil), do: false
  defp valid_program?(%{title: nil}), do: false
  defp valid_program?(%{title: ""}), do: false
  defp valid_program?(%{start_time: nil}), do: false
  defp valid_program?(%{end_time: nil}), do: false
  defp valid_program?(%{} = m) when not is_map_key(m, :title), do: false
  defp valid_program?(_), do: true

  @doc """
  Decodes a base64-encoded field.
  Xtream Codes encodes title and description in base64.
  """
  def decode_base64_field(nil), do: nil
  def decode_base64_field(""), do: nil

  def decode_base64_field(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} ->
        # Clean up the decoded string
        decoded
        |> String.trim()
        |> case do
          "" -> nil
          str -> str
        end

      :error ->
        # Not base64 encoded, return as-is
        String.trim(value)
    end
  end

  def decode_base64_field(_), do: nil

  @doc """
  Parses a Unix timestamp or datetime string into DateTime.
  """
  def parse_timestamp(unix_ts, _fallback) when is_integer(unix_ts) and unix_ts > 0 do
    case DateTime.from_unix(unix_ts) do
      {:ok, dt} -> dt
      {:error, _} -> nil
    end
  end

  def parse_timestamp(unix_ts, fallback) when is_binary(unix_ts) do
    case Integer.parse(unix_ts) do
      {ts, _} when ts > 0 -> parse_timestamp(ts, fallback)
      _ -> parse_datetime_string(fallback)
    end
  end

  def parse_timestamp(_, fallback), do: parse_datetime_string(fallback)

  defp parse_datetime_string(nil), do: nil
  defp parse_datetime_string(""), do: nil

  defp parse_datetime_string(str) when is_binary(str) do
    # Try parsing common formats: "2024-01-01 10:00:00"
    case NaiveDateTime.from_iso8601(String.replace(str, " ", "T")) do
      {:ok, naive} ->
        DateTime.from_naive!(naive, "Etc/UTC")

      {:error, _} ->
        # Try with space separator
        case Regex.run(~r/(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/, str) do
          [_, y, m, d, h, min, s] ->
            {:ok, naive} =
              NaiveDateTime.new(
                String.to_integer(y),
                String.to_integer(m),
                String.to_integer(d),
                String.to_integer(h),
                String.to_integer(min),
                String.to_integer(s)
              )

            DateTime.from_naive!(naive, "Etc/UTC")

          _ ->
            nil
        end
    end
  end

  defp parse_datetime_string(_), do: nil
end
