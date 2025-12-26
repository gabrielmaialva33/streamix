defmodule Streamix.Iptv.ParserTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Parser

  describe "parse/1" do
    test "parses valid M3U content with all attributes" do
      content = """
      #EXTM3U
      #EXTINF:-1 tvg-id="ch1" tvg-name="Channel One" tvg-logo="http://logo.com/1.png" group-title="News",Channel 1
      http://stream.example.com/1.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Channel 1"
      assert channel.stream_url == "http://stream.example.com/1.ts"
      assert channel.logo_url == "http://logo.com/1.png"
      assert channel.tvg_id == "ch1"
      assert channel.tvg_name == "Channel One"
      assert channel.group_title == "News"
    end

    test "parses multiple channels" do
      content = """
      #EXTM3U
      #EXTINF:-1 tvg-id="ch1" group-title="News",Channel 1
      http://stream.example.com/1.ts
      #EXTINF:-1 tvg-id="ch2" group-title="Sports",Channel 2
      http://stream.example.com/2.ts
      #EXTINF:-1 tvg-id="ch3" group-title="Movies",Channel 3
      http://stream.example.com/3.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert length(channels) == 3
      assert Enum.map(channels, & &1.name) == ["Channel 1", "Channel 2", "Channel 3"]
      assert Enum.map(channels, & &1.group_title) == ["News", "Sports", "Movies"]
    end

    test "handles missing optional attributes" do
      content = """
      #EXTM3U
      #EXTINF:-1,Simple Channel
      http://stream.example.com/simple.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Simple Channel"
      assert channel.stream_url == "http://stream.example.com/simple.ts"
      assert is_nil(channel.logo_url)
      assert is_nil(channel.tvg_id)
      assert is_nil(channel.tvg_name)
      assert is_nil(channel.group_title)
    end

    test "handles HTTPS URLs" do
      content = """
      #EXTM3U
      #EXTINF:-1,HTTPS Channel
      https://secure.example.com/stream.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.stream_url == "https://secure.example.com/stream.ts"
    end

    test "ignores lines without valid URLs" do
      content = """
      #EXTM3U
      #EXTINF:-1,Valid Channel
      http://stream.example.com/1.ts
      #EXTINF:-1,Invalid Channel
      not-a-valid-url
      #EXTINF:-1,Another Valid
      http://stream.example.com/2.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert length(channels) == 2
      assert Enum.map(channels, & &1.name) == ["Valid Channel", "Another Valid"]
    end

    test "handles empty content" do
      channels = "" |> Parser.parse() |> Enum.to_list()
      assert channels == []
    end

    test "handles content without EXTM3U header" do
      content = """
      #EXTINF:-1,Channel 1
      http://stream.example.com/1.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Channel 1"
    end

    test "handles channel names with commas" do
      content = """
      #EXTM3U
      #EXTINF:-1 tvg-id="ch1",Channel Name, With Commas
      http://stream.example.com/1.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Channel Name, With Commas"
    end

    test "handles channel names with special characters" do
      content = """
      #EXTM3U
      #EXTINF:-1,Canal Brasil HD 🇧🇷
      http://stream.example.com/brasil.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Canal Brasil HD 🇧🇷"
    end

    test "skips comment lines between EXTINF and URL" do
      content = """
      #EXTM3U
      #EXTINF:-1,Channel 1
      #EXTVLCOPT:some-option=value
      http://stream.example.com/1.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Channel 1"
    end

    test "handles consecutive EXTINF lines (missing URLs)" do
      content = """
      #EXTM3U
      #EXTINF:-1,Missing URL Channel
      #EXTINF:-1,Valid Channel
      http://stream.example.com/valid.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Valid Channel"
    end

    test "trims whitespace from lines" do
      content = """
      #EXTM3U
        #EXTINF:-1,Channel 1
        http://stream.example.com/1.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Channel 1"
      assert channel.stream_url == "http://stream.example.com/1.ts"
    end

    test "handles positive duration values" do
      content = """
      #EXTM3U
      #EXTINF:120 tvg-id="ch1",Channel 1
      http://stream.example.com/1.ts
      """

      channels = content |> Parser.parse() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Channel 1"
      assert channel.tvg_id == "ch1"
    end
  end

  describe "parse_stream/1" do
    test "works with any enumerable" do
      lines = [
        "#EXTM3U",
        "#EXTINF:-1,Channel 1",
        "http://stream.example.com/1.ts"
      ]

      channels = lines |> Parser.parse_stream() |> Enum.to_list()

      assert [channel] = channels
      assert channel.name == "Channel 1"
    end
  end

  describe "group_by_category/1" do
    test "groups channels by group_title" do
      channels = [
        %{name: "Ch1", group_title: "News"},
        %{name: "Ch2", group_title: "Sports"},
        %{name: "Ch3", group_title: "News"},
        %{name: "Ch4", group_title: nil}
      ]

      grouped = Parser.group_by_category(channels)

      assert Map.keys(grouped) |> Enum.sort() == [nil, "News", "Sports"]
      assert length(grouped["News"]) == 2
      assert length(grouped["Sports"]) == 1
      assert length(grouped[nil]) == 1
    end
  end

  describe "get_categories/1" do
    test "returns unique sorted categories" do
      channels = [
        %{group_title: "Sports"},
        %{group_title: "News"},
        %{group_title: "Sports"},
        %{group_title: "Movies"},
        %{group_title: nil}
      ]

      categories = Parser.get_categories(channels)

      assert categories == ["Movies", "News", "Sports"]
    end

    test "returns empty list for empty input" do
      assert Parser.get_categories([]) == []
    end

    test "works with streams" do
      stream =
        Stream.repeatedly(fn -> %{group_title: "Test"} end)
        |> Stream.take(3)

      categories = Parser.get_categories(stream)

      assert categories == ["Test"]
    end
  end
end
