defmodule Streamix.Subtitles.VttTest do
  use ExUnit.Case, async: true

  alias Streamix.Subtitles.Vtt

  test "converts SRT to WebVTT with header and dot millisecond separator" do
    srt = """
    1
    00:00:01,000 --> 00:00:04,000
    Olá mundo

    2
    00:00:05,500 --> 00:00:08,250
    Segunda linha
    """

    vtt = Vtt.from_srt(srt)

    assert String.starts_with?(vtt, "WEBVTT\n\n")
    assert vtt =~ "00:00:01.000 --> 00:00:04.000"
    assert vtt =~ "00:00:05.500 --> 00:00:08.250"
    assert vtt =~ "Olá mundo"
    refute vtt =~ ","
  end

  test "is idempotent for content already in WebVTT" do
    vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n"
    assert Vtt.from_srt(vtt) == vtt
  end

  test "strips a UTF-8 BOM" do
    srt = <<0xEF, 0xBB, 0xBF>> <> "1\n00:00:01,000 --> 00:00:02,000\nhi\n"
    vtt = Vtt.from_srt(srt)
    assert String.starts_with?(vtt, "WEBVTT")
    refute String.contains?(vtt, <<0xEF, 0xBB, 0xBF>>)
  end

  test "normalizes CRLF line endings" do
    srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nhi\r\n"
    vtt = Vtt.from_srt(srt)
    refute vtt =~ "\r"
    assert vtt =~ "00:00:01.000 --> 00:00:02.000"
  end
end
