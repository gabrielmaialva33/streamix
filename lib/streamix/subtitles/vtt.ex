defmodule Streamix.Subtitles.Vtt do
  @moduledoc """
  Minimal SubRip (`.srt`) → WebVTT (`.vtt`) conversion.

  External subtitle providers ship SRT almost universally; the player
  (and browsers) want WebVTT. The transform is small but real: VTT needs
  a `WEBVTT` header and `.` (not `,`) as the millisecond separator in cue
  timestamps. Cue numbering is optional in VTT, so we keep the lines
  as-is otherwise — this stays format-preserving for styling/positioning
  a provider might include.
  """

  @doc """
  Converts SRT text to WebVTT. Idempotent: input already starting with
  `WEBVTT` is returned untouched (minus a BOM).
  """
  @spec from_srt(binary()) :: binary()
  def from_srt(srt) when is_binary(srt) do
    srt = strip_bom(srt)

    if String.starts_with?(srt, "WEBVTT") do
      srt
    else
      body =
        srt
        |> String.replace("\r\n", "\n")
        |> convert_timestamps()

      "WEBVTT\n\n" <> body
    end
  end

  @doc """
  Shifts every cue by `offset_ms`, clamping negative timestamps at zero.
  Positive offsets delay subtitles; negative offsets advance them.
  """
  @spec shift(binary(), integer()) :: binary()
  def shift(vtt, 0) when is_binary(vtt), do: vtt

  def shift(vtt, offset_ms) when is_binary(vtt) and is_integer(offset_ms) do
    Regex.replace(
      ~r/(\d{2,}:\d{2}:\d{2}[.,]\d{3})(\s+-->\s+)(\d{2,}:\d{2}:\d{2}[.,]\d{3})/,
      vtt,
      fn _full, start_at, separator, end_at ->
        shifted_start = start_at |> timestamp_to_ms() |> Kernel.+(offset_ms) |> max(0)
        shifted_end = end_at |> timestamp_to_ms() |> Kernel.+(offset_ms) |> max(shifted_start)
        "#{format_timestamp(shifted_start)}#{separator}#{format_timestamp(shifted_end)}"
      end
    )
  end

  # 00:00:01,000 --> 00:00:04,000  =>  00:00:01.000 --> 00:00:04.000
  defp convert_timestamps(text) do
    Regex.replace(
      ~r/(\d{2}:\d{2}:\d{2}),(\d{3})/,
      text,
      fn _full, hms, ms -> "#{hms}.#{ms}" end
    )
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(text), do: text

  defp timestamp_to_ms(timestamp) do
    [hours, minutes, seconds_ms] = String.split(timestamp, ":")
    [seconds, milliseconds] = String.split(seconds_ms, ~r/[.,]/)

    String.to_integer(hours) * 3_600_000 +
      String.to_integer(minutes) * 60_000 +
      String.to_integer(seconds) * 1_000 +
      String.to_integer(milliseconds)
  end

  defp format_timestamp(total_ms) do
    hours = div(total_ms, 3_600_000)
    minutes = div(rem(total_ms, 3_600_000), 60_000)
    seconds = div(rem(total_ms, 60_000), 1_000)
    milliseconds = rem(total_ms, 1_000)

    "#{pad(hours, 2)}:#{pad(minutes, 2)}:#{pad(seconds, 2)}.#{pad(milliseconds, 3)}"
  end

  defp pad(value, width), do: value |> Integer.to_string() |> String.pad_leading(width, "0")
end
