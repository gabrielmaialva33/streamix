defmodule Streamix.AI.Embeddings do
  @moduledoc """
  Unified embeddings interface supporting multiple providers.

  Supports:
  - Google Gemini (3072 dimensions) - Default
  - NVIDIA NIM (1024 dimensions)

  ## Configuration

  Set `EMBEDDING_PROVIDER` to choose provider:
  - `gemini` (default) - Google Gemini embeddings
  - `nvidia` - NVIDIA NIM embeddings

  ## Fallback

  If primary provider fails, automatically falls back to the other.
  Note: Fallback only works if both providers are configured and
  the Qdrant collection was created with the fallback provider's dimensions.
  """

  require Logger

  alias Streamix.AI.{Gemini, Nvidia}

  @doc """
  Returns the current embedding dimensions based on configured provider.
  """
  def embedding_dimensions do
    case provider() do
      :nvidia -> Nvidia.embedding_dimensions()
      _ -> Gemini.embedding_dimensions()
    end
  end

  @doc """
  Returns the configured provider.
  """
  def provider do
    case get_provider_config() do
      "nvidia" -> :nvidia
      _ -> :gemini
    end
  end

  @doc """
  Checks if embeddings are available (at least one provider configured).
  """
  def enabled? do
    Gemini.enabled?() or Nvidia.enabled?()
  end

  @doc """
  Checks if both providers are available for fallback.
  """
  def fallback_available? do
    Gemini.enabled?() and Nvidia.enabled?()
  end

  @doc """
  Generates embedding for a single text.
  Uses configured provider with fallback.
  """
  def embed(text) when is_binary(text) do
    case provider() do
      :nvidia -> embed_with_fallback(text, :nvidia, :gemini)
      :gemini -> embed_with_fallback(text, :gemini, :nvidia)
    end
  end

  @doc """
  Generates embeddings for multiple texts.
  Uses configured provider with fallback.
  """
  def embed_batch(texts) when is_list(texts) do
    case provider() do
      :nvidia -> embed_batch_with_fallback(texts, :nvidia, :gemini)
      :gemini -> embed_batch_with_fallback(texts, :gemini, :nvidia)
    end
  end

  @doc """
  Generates embedding for content (movie, series, etc).
  """
  def embed_content(content) do
    case provider() do
      :nvidia -> Nvidia.embed_content(content)
      :gemini -> Gemini.embed_content(content)
    end
  end

  @doc """
  Generates embeddings for multiple content items.
  """
  def embed_contents(contents) when is_list(contents) do
    case provider() do
      :nvidia -> Nvidia.embed_contents(contents)
      :gemini -> Gemini.embed_contents(contents)
    end
  end

  @doc """
  Returns info about current configuration.
  """
  def info do
    %{
      provider: provider(),
      dimensions: embedding_dimensions(),
      gemini_enabled: Gemini.enabled?(),
      nvidia_enabled: Nvidia.enabled?(),
      fallback_available: fallback_available?()
    }
  end

  # Private functions

  defp get_provider_config do
    Application.get_env(:streamix, :embeddings, [])[:provider] ||
      System.get_env("EMBEDDING_PROVIDER") ||
      "nvidia"
  end

  defp embed_with_fallback(text, primary, fallback) do
    case do_embed(text, primary) do
      {:ok, _} = result ->
        result

      {:error, reason} ->
        Logger.warning("[Embeddings] #{primary} failed: #{inspect(reason)}, trying #{fallback}")

        if provider_enabled?(fallback) do
          do_embed(text, fallback)
        else
          {:error, reason}
        end
    end
  end

  defp embed_batch_with_fallback(texts, primary, fallback) do
    case do_embed_batch(texts, primary) do
      {:ok, _} = result ->
        result

      {:error, reason} ->
        Logger.warning(
          "[Embeddings] #{primary} batch failed: #{inspect(reason)}, trying #{fallback}"
        )

        if provider_enabled?(fallback) do
          do_embed_batch(texts, fallback)
        else
          {:error, reason}
        end
    end
  end

  defp do_embed(text, :gemini), do: Gemini.embed(text)
  defp do_embed(text, :nvidia), do: Nvidia.embed(text)

  defp do_embed_batch(texts, :gemini), do: Gemini.embed_batch(texts)
  defp do_embed_batch(texts, :nvidia), do: Nvidia.embed_batch(texts)

  defp provider_enabled?(:gemini), do: Gemini.enabled?()
  defp provider_enabled?(:nvidia), do: Nvidia.enabled?()
end
