defmodule StreamixWeb.UrlValidatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias StreamixWeb.UrlValidator

  describe "validate_url/1" do
    test "allows http URLs with public IPs" do
      assert :ok = UrlValidator.validate_url("http://93.184.216.34/stream.ts")
      assert :ok = UrlValidator.validate_url("https://1.1.1.1/live/123.m3u8")
    end

    test "allows https URLs" do
      assert :ok = UrlValidator.validate_url("https://8.8.8.8/video.mp4")
    end

    test "blocks non-http schemes" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("ftp://evil.com/file")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("file:///etc/passwd")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("gopher://evil.com/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("javascript:alert(1)")
      end)
    end

    test "blocks URLs without a host" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("")
      end)
    end

    test "blocks localhost" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://127.0.0.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://127.0.0.2:8080/api")
      end)
    end

    test "blocks 10.x.x.x private range" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://10.0.0.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://10.18.0.54:9090/")
      end)
    end

    test "blocks 172.16-31.x.x private range" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://172.16.0.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://172.31.255.255/")
      end)
    end

    test "allows 172.x outside private range" do
      assert :ok = UrlValidator.validate_url("http://172.15.0.1/")
      assert :ok = UrlValidator.validate_url("http://172.32.0.1/")
    end

    test "blocks 192.168.x.x private range" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://192.168.1.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://192.168.0.100:8080/")
      end)
    end

    test "blocks AWS metadata endpoint" do
      capture_log(fn ->
        assert {:error, :unsafe_url} =
                 UrlValidator.validate_url("http://169.254.169.254/latest/meta-data/")
      end)
    end

    test "blocks 0.0.0.0" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://0.0.0.0/")
      end)
    end

    test "blocks non-string input" do
      assert {:error, :unsafe_url} = UrlValidator.validate_url(nil)
      assert {:error, :unsafe_url} = UrlValidator.validate_url(123)
    end
  end
end
