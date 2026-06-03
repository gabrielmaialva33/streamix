defmodule StreamixWeb.Api.Envelope do
  @moduledoc """
  Standard response envelope helpers for `/api/v1` JSON responses.

  The audit (deep review #4) found that controllers each invented their
  own response shape (`%{movies: [...]}`, `%{items: [...]}`, plain map,
  …) and error shape (`%{error: "string"}` vs `%{error: %{code, message}}`).
  This module is the one place that knows the contract — controllers
  should call `data/2` and `error/3` instead of building maps inline.

  ## Success shape

      %{
        data: <payload>,
        meta: %{
          version: "v1",
          # optional, only when caller passes :pagination opt:
          pagination: %{total: ..., limit: ..., offset: ..., has_more: ...}
        }
      }

  ## Error shape

      %{
        error: %{
          code: :atom_as_snake_case_string,
          message: "Humanized message",
          details: %{}     # optional, only when caller passes
        }
      }

  Migration path: controllers can adopt incrementally. Old shapes still
  work in TV apps that hard-coded them, so callers should bump their
  client minor version after switching.
  """

  @api_version "v1"

  @doc """
  Wraps `payload` in the canonical success envelope. `opts[:pagination]`
  attaches a pagination block; otherwise only `:version` lives in meta.
  """
  @spec data(term(), keyword()) :: map()
  def data(payload, opts \\ []) do
    meta = %{version: @api_version}

    meta =
      case Keyword.get(opts, :pagination) do
        nil -> meta
        pagination -> Map.put(meta, :pagination, pagination)
      end

    %{data: payload, meta: meta}
  end

  @doc """
  Builds the canonical error envelope. `code` is forced to an atom-like
  snake_case string so machine clients can switch on it; `message` is the
  humanized text.
  """
  @spec error(atom() | String.t(), String.t(), map()) :: map()
  def error(code, message, details \\ %{}) do
    body = %{code: to_code(code), message: message}
    body = if map_size(details) > 0, do: Map.put(body, :details, details), else: body
    %{error: body}
  end

  @doc """
  Convenience: build a pagination meta from common `?limit=&offset=` +
  the resolved `total`. Returns a map ready to pass as `:pagination` opt
  to `data/2`.
  """
  @spec pagination(integer(), integer(), integer()) :: map()
  def pagination(total, limit, offset) when is_integer(total) and total >= 0 do
    %{
      total: total,
      limit: limit,
      offset: offset,
      has_more: offset + limit < total
    }
  end

  defp to_code(code) when is_atom(code), do: Atom.to_string(code)
  defp to_code(code) when is_binary(code), do: code
end
