defmodule Streamix.AI.NvidiaTest do
  @moduledoc """
  The vector size is a property of the embedding model, so it has to move with
  `NVIDIA_EMBEDDING_MODEL`.

  It used to be a constant while the model was configurable, which let the two
  disagree silently — and a model swap that happens to keep the same vector
  size is exactly the case `Streamix.AI.SearchHealth` documents it cannot
  detect from Qdrant alone.
  """

  use ExUnit.Case, async: false

  alias Streamix.AI.Nvidia

  setup do
    original = Application.get_env(:streamix, :nvidia)

    on_exit(fn ->
      if original,
        do: Application.put_env(:streamix, :nvidia, original),
        else: Application.delete_env(:streamix, :nvidia)
    end)

    :ok
  end

  defp put_nvidia(opts), do: Application.put_env(:streamix, :nvidia, opts)

  test "reports the size of the configured model" do
    put_nvidia(api_key: "test", embedding_model: "nvidia/nemotron-3-embed-1b")
    assert Nvidia.embedding_dimensions() == 2048

    put_nvidia(api_key: "test", embedding_model: "nvidia/nv-embedqa-e5-v5")
    assert Nvidia.embedding_dimensions() == 1024
  end

  test "defaults to a model that is still served" do
    # nv-embedqa-e5-v5 reached end of life on 2026-08-25 and answers 410, so a
    # deployment that sets no model at all must not land on it.
    put_nvidia(api_key: "test")
    assert Nvidia.embedding_dimensions() == 2048
  end

  test "an explicit dimension setting wins, for a model the app does not know" do
    put_nvidia(api_key: "test", embedding_model: "vendor/brand-new", embedding_dimensions: 768)
    assert Nvidia.embedding_dimensions() == 768
  end

  test "an unknown model without an explicit size falls back to the default" do
    put_nvidia(api_key: "test", embedding_model: "vendor/brand-new")
    assert Nvidia.embedding_dimensions() == 2048
  end

  test "a nil dimension setting is ignored rather than taken literally" do
    # runtime.exs passes nil when NVIDIA_EMBEDDING_DIMENSIONS is unset.
    put_nvidia(
      api_key: "test",
      embedding_model: "nvidia/nv-embedqa-e5-v5",
      embedding_dimensions: nil
    )

    assert Nvidia.embedding_dimensions() == 1024
  end
end
