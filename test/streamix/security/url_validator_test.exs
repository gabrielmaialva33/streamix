defmodule Streamix.Security.UrlValidatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Streamix.Security.UrlValidator

  describe "validate_url/1" do
    test "allows http and https URLs with public IP literals" do
      assert :ok = UrlValidator.validate_url("http://93.184.216.34/stream.ts")
      assert :ok = UrlValidator.validate_url("https://93.184.216.34/video.mp4")
    end

    test "blocks unsafe schemes and missing hosts" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("file:///etc/passwd")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("javascript:alert(1)")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://")
      end)
    end

    test "blocks private and metadata IP literals" do
      capture_log(fn ->
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://127.0.0.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://10.0.0.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://172.16.0.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://192.168.1.1/")
        assert {:error, :unsafe_url} = UrlValidator.validate_url("http://169.254.169.254/")
      end)
    end

    test "allows a private target only for an explicitly trusted server-side provider" do
      assert :ok =
               UrlValidator.validate_url("http://10.8.0.10/player_api.php",
                 allow_private_network: true
               )
    end
  end
end
