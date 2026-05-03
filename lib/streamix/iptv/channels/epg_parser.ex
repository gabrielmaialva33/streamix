defmodule Streamix.Iptv.EpgParser do
  @moduledoc """
  Parser for EPG data from Xtream Codes API.

  Two formats are supported:

  * **`get_short_epg`** JSON response — base64-encoded fields, used for
    on-demand single-channel queries.
  * **XMLTV** (returned by `/xmltv.php`) — single document covering the
    full catalog. Used by `SyncEpgWorker`.
  """

  import SweetXml, only: [sigil_x: 2]

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
    programmes =
      xml
      |> SweetXml.parse(quiet: true)
      |> SweetXml.xpath(
        ~x"//programme"l,
        channel: ~x"./@channel"s,
        start: ~x"./@start"s,
        stop: ~x"./@stop"s,
        title: ~x"./title/text()"s,
        desc: ~x"./desc/text()"s,
        category: ~x"./category/text()"s,
        icon: ~x"./icon/@src"s,
        lang: ~x"./title/@lang"s
      )

    grouped =
      programmes
      |> Enum.map(&xmltv_to_program/1)
      |> Enum.filter(&valid_program?/1)
      |> Enum.group_by(& &1.channel_external_id)

    {:ok, grouped}
  rescue
    e -> {:error, {:xmltv_parse_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:xmltv_parse_failed, reason}}
  end

  def parse_xmltv(_), do: {:error, :invalid_xmltv}

  defp xmltv_to_program(%{channel: ch} = p) when is_binary(ch) and ch != "" do
    %{
      channel_external_id: ch,
      title: blank_to_nil(p[:title]),
      description: blank_to_nil(p[:desc]),
      start_time: parse_xmltv_datetime(p[:start]),
      end_time: parse_xmltv_datetime(p[:stop]),
      category: blank_to_nil(p[:category]),
      icon: blank_to_nil(p[:icon]),
      lang: blank_to_nil(p[:lang])
    }
  end

  defp xmltv_to_program(_), do: nil

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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s |> String.trim() |> blank_to_nil()
  defp blank_to_nil(_), do: nil

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
