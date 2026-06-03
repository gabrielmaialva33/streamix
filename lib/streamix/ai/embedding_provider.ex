defmodule Streamix.AI.EmbeddingProvider do
  @moduledoc """
  Behaviour every embedding backend (`Gemini`, `Nvidia`, future providers)
  implements.

  Streamix.AI.Embeddings dispatches to the configured provider with a
  fallback to the secondary one, and now-runtime checks vector dimensions
  match before allowing the fallback (otherwise the Qdrant collection,
  which was created with the primary's dimension, rejects the insert).
  Defining the shape as a behaviour makes the contract explicit, gives
  Dialyzer something to chew on, and is what lets new backends slot in
  without editing `embeddings.ex`.
  """

  @typedoc "A free-text input ready for embedding"
  @type text :: String.t()

  @typedoc "Content row shape — minimum keys the providers consume"
  @type content :: %{optional(:title) => String.t(), optional(:plot) => String.t()}

  @doc "Vector dimensionality returned by `embed/1,2` for this provider."
  @callback embedding_dimensions() :: pos_integer()

  @doc "Whether the provider has the credentials/endpoints it needs."
  @callback enabled?() :: boolean()

  @doc """
  Embed a single piece of free text. `opts` is a keyword list — at least
  `:input_type` (`:query | :passage`) is honoured by every provider.
  """
  @callback embed(text(), keyword()) :: {:ok, [float()]} | {:error, term()}

  @doc "Batched form of `embed/2`."
  @callback embed_batch([text()], keyword()) ::
              {:ok, [[float()]]} | {:error, term()}

  @doc "Embed a content row (title + plot + …) — providers build the prompt."
  @callback embed_content(content()) :: {:ok, [float()]} | {:error, term()}

  @doc "Batched form of `embed_content/1`."
  @callback embed_contents([content()]) :: {:ok, [[float()]]} | {:error, term()}

  @optional_callbacks [embed_contents: 1, embed_batch: 2]
end
