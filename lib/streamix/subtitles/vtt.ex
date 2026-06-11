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
end
