defmodule Streamix.Iptv.EpgParserTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.EpgParser

  describe "parse_short_epg/1" do
    test "parses valid EPG listings" do
      # "News at Ten" in base64
      title_b64 = Base.encode64("News at Ten")
      # "Daily news program" in base64
      desc_b64 = Base.encode64("Daily news program")

      input = %{
        "epg_listings" => [
          %{
            "id" => "12345",
            "channel_id" => "ch1",
            "title" => title_b64,
            "description" => desc_b64,
            "start" => "2024-01-01 10:00:00",
            "end" => "2024-01-01 11:00:00",
            "start_timestamp" => 1_704_103_200,
            "stop_timestamp" => 1_704_106_800,
            "lang" => "en",
            "category" => "News"
          }
        ]
      }

      assert {:ok, [program]} = EpgParser.parse_short_epg(input)

      assert program.epg_channel_id == "ch1"
      assert program.title == "News at Ten"
      assert program.description == "Daily news program"
      assert program.lang == "en"
      assert program.category == "News"
      assert %DateTime{} = program.start_time
      assert %DateTime{} = program.end_time
    end

    test "filters out programs with missing title" do
      input = %{
        "epg_listings" => [
          %{
            "channel_id" => "ch1",
            "title" => "",
            "start_timestamp" => 1_704_103_200,
            "stop_timestamp" => 1_704_106_800
          }
        ]
      }

      assert {:ok, []} = EpgParser.parse_short_epg(input)
    end

    test "filters out programs with missing timestamps" do
      input = %{
        "epg_listings" => [
          %{
            "channel_id" => "ch1",
            "title" => Base.encode64("Test"),
            "start_timestamp" => nil,
            "stop_timestamp" => nil
          }
        ]
      }

      assert {:ok, []} = EpgParser.parse_short_epg(input)
    end

    test "returns empty list for invalid input" do
      assert {:ok, []} = EpgParser.parse_short_epg(nil)
      assert {:ok, []} = EpgParser.parse_short_epg(%{})
      assert {:ok, []} = EpgParser.parse_short_epg(%{"epg_listings" => "invalid"})
    end

    test "uses epg_id as fallback for channel_id" do
      input = %{
        "epg_listings" => [
          %{
            "epg_id" => "epg123",
            "title" => Base.encode64("Test Program"),
            "start_timestamp" => 1_704_103_200,
            "stop_timestamp" => 1_704_106_800
          }
        ]
      }

      assert {:ok, [program]} = EpgParser.parse_short_epg(input)
      assert program.epg_channel_id == "epg123"
    end
  end

  describe "decode_base64_field/1" do
    test "decodes valid base64 string" do
      encoded = Base.encode64("Hello World")
      assert EpgParser.decode_base64_field(encoded) == "Hello World"
    end

    test "returns nil for empty string" do
      assert EpgParser.decode_base64_field("") == nil
    end

    test "returns nil for nil" do
      assert EpgParser.decode_base64_field(nil) == nil
    end

    test "returns trimmed original for non-base64 string" do
      assert EpgParser.decode_base64_field("  plain text  ") == "plain text"
    end

    test "returns nil for base64 that decodes to empty string" do
      # Base64 of empty string or whitespace
      assert EpgParser.decode_base64_field(Base.encode64("   ")) == nil
    end

    test "handles UTF-8 encoded in base64" do
      encoded = Base.encode64("Película de Acción")
      assert EpgParser.decode_base64_field(encoded) == "Película de Acción"
    end
  end

  describe "parse_timestamp/2" do
    test "parses Unix timestamp integer" do
      # 2024-01-01 10:00:00 UTC
      unix_ts = 1_704_103_200
      result = EpgParser.parse_timestamp(unix_ts, nil)

      assert %DateTime{} = result
      assert result.year == 2024
      assert result.month == 1
      assert result.day == 1
    end

    test "parses Unix timestamp as string" do
      result = EpgParser.parse_timestamp("1704103200", nil)
      assert %DateTime{} = result
      assert result.year == 2024
    end

    test "falls back to datetime string when timestamp invalid" do
      result = EpgParser.parse_timestamp(nil, "2024-06-15 14:30:00")

      assert %DateTime{} = result
      assert result.year == 2024
      assert result.month == 6
      assert result.day == 15
      assert result.hour == 14
      assert result.minute == 30
    end

    test "returns nil for invalid timestamp and fallback" do
      assert EpgParser.parse_timestamp(nil, nil) == nil
      assert EpgParser.parse_timestamp("invalid", "also invalid") == nil
    end

    test "handles negative or zero timestamp" do
      assert EpgParser.parse_timestamp(0, "2024-01-01 10:00:00") != nil
      assert EpgParser.parse_timestamp(-1, "2024-01-01 10:00:00") != nil
    end
  end
end
