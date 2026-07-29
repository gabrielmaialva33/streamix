defmodule Streamix.BuildInfo do
  @moduledoc """
  Credential-free release identity shared by health checks and PWA assets.

  `STREAMIX_REVISION` is baked into the production image from the Git SHA. The
  asset version follows Phoenix's digest manifest so it changes with the
  browser payload, even when the Service Worker source itself did not change.
  """

  @sw_path "sw.js"
  @manifest_path "cache_manifest.json"

  @doc """
  Returns the release version, source revision and browser asset version.
  """
  def snapshot do
    %{
      version: application_version(),
      revision: revision(),
      asset_version: asset_version()
    }
  end

  def revision do
    case System.get_env("STREAMIX_REVISION") do
      revision when is_binary(revision) and revision != "" -> revision
      _ -> "unknown"
    end
  end

  def asset_version do
    manifest_file =
      :streamix
      |> Application.app_dir("priv/static")
      |> Path.join(@manifest_path)

    case File.read(manifest_file) do
      {:ok, contents} ->
        content_version(contents)

      _ ->
        development_asset_version()
    end
  end

  defp application_version do
    case Application.spec(:streamix, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _ -> "unknown"
    end
  end

  defp content_version(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp development_asset_version do
    sw_file = Path.join(Application.app_dir(:streamix, "priv"), @sw_path)

    case File.read(sw_file) do
      {:ok, contents} ->
        "dev-" <> content_version(contents)

      _ ->
        "dev-fallback"
    end
  end
end
