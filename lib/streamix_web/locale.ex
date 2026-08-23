defmodule StreamixWeb.Locale do
  @moduledoc """
  Canonical locale policy shared by browser requests and LiveView processes.

  Database values use Gettext locale identifiers while `html_lang/1` exposes
  the corresponding BCP 47 language tag. Unsupported or malformed input always
  falls back to Brazilian Portuguese.
  """

  @default "pt_BR"
  @supported %{
    "pt_BR" => %{label: "Português (Brasil)", html_lang: "pt-BR"},
    "en" => %{label: "English", html_lang: "en"}
  }

  @type locale :: String.t()

  @doc "Returns the default application locale."
  @spec default() :: locale()
  def default, do: @default

  @doc "Returns persisted locale options for account settings."
  @spec options() :: [{String.t(), locale()}]
  def options do
    Enum.map(@supported, fn {locale, %{label: label}} -> {label, locale} end)
    |> Enum.sort_by(fn {_label, locale} -> if locale == @default, do: 0, else: 1 end)
  end

  @doc "Resolves user, session, and Accept-Language preferences in priority order."
  @spec resolve(term(), term(), term()) :: locale()
  def resolve(user_locale, session_locale, accept_language) do
    normalize(user_locale) || normalize(session_locale) || from_accept_language(accept_language) ||
      @default
  end

  @doc "Normalizes known database, browser, and BCP 47 locale spellings."
  @spec normalize(term()) :: locale() | nil
  def normalize(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.replace("-", "_")
      |> String.downcase()

    cond do
      normalized in ["pt", "pt_br"] -> "pt_BR"
      normalized == "en" -> "en"
      String.starts_with?(normalized, "en_") -> "en"
      true -> nil
    end
  end

  def normalize(_value), do: nil

  @doc "Returns the BCP 47 tag used by the document language attribute."
  @spec html_lang(locale()) :: String.t()
  def html_lang(locale) do
    locale = normalize(locale) || @default
    get_in(@supported, [locale, :html_lang]) || "pt-BR"
  end

  @doc "Applies a locale to the Streamix Gettext backend and returns it."
  @spec put(locale()) :: locale()
  def put(locale) do
    locale = normalize(locale) || @default
    Gettext.put_locale(StreamixWeb.Gettext, locale)
    locale
  end

  defp from_accept_language(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&parse_language_range/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_locale, quality, index} -> {-quality, index} end)
    |> List.first()
    |> case do
      {locale, _quality, _index} -> locale
      nil -> nil
    end
  end

  defp from_accept_language(_value), do: nil

  defp parse_language_range(range) do
    [language | params] = String.split(range, ";", parts: 2)
    locale = normalize(language)
    quality = parse_quality(params)

    if locale, do: {locale, quality, language_index(language)}, else: nil
  end

  defp parse_quality([]), do: 1.0

  defp parse_quality([params]) do
    case Regex.run(~r/(?:^|;)\s*q=([0-9.]+)/i, params) do
      [_, value] -> parse_quality_value(value)
      _match -> 1.0
    end
  end

  defp parse_quality_value(value) do
    case Float.parse(value) do
      {quality, ""} -> max(0.0, min(1.0, quality))
      _other -> 0.0
    end
  end

  defp language_index(language) do
    language
    |> String.trim()
    |> String.downcase()
    |> case do
      "pt-br" -> 0
      "pt_br" -> 0
      "pt" -> 1
      "en" -> 2
      _value -> 3
    end
  end
end
