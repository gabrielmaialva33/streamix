defmodule Streamix.Iptv.EpgParser do
  @moduledoc """
  Parser for EPG data from Xtream Codes API.

  The Xtream Codes API returns EPG data with base64-encoded fields
  and Unix timestamps that need to be converted.
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
