defmodule Streamix.Iptv.EpgXmltvHandler do
  @moduledoc false
  @behaviour Saxy.Handler

  @impl Saxy.Handler
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:end_document, _data, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:start_element, {"programme", attrs}, state) do
    programme = %{
      channel_external_id: attr(attrs, "channel"),
      start_time: attrs |> attr("start") |> parse_datetime(),
      end_time: attrs |> attr("stop") |> parse_datetime()
    }

    {:ok, %{state | current: programme, char_buf: nil}}
  end

  def handle_event(:start_element, {name, attrs}, %{current: current} = state)
      when not is_nil(current) do
    case name do
      "icon" ->
        {:ok, %{state | current: Map.put(current, :icon, attr(attrs, "src")), char_buf: nil}}

      "title" ->
        current = Map.put_new(current, :lang, attr(attrs, "lang"))
        {:ok, %{state | current: current, char_buf: []}}

      name when name in ["desc", "category", "sub-title", "episode-num"] ->
        {:ok, %{state | char_buf: []}}

      _other ->
        {:ok, %{state | char_buf: nil}}
    end
  end

  def handle_event(:start_element, _element, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:characters, chars, %{char_buf: buffer} = state) when is_list(buffer) do
    {:ok, %{state | char_buf: [chars | buffer]}}
  end

  def handle_event(:characters, _chars, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:end_element, "programme", %{current: current} = state)
      when not is_nil(current) do
    {:ok, %{state | programmes: [current | state.programmes], current: nil, char_buf: nil}}
  end

  def handle_event(:end_element, name, %{current: current, char_buf: buffer} = state)
      when not is_nil(current) and is_list(buffer) do
    current =
      case field_for_element(name) do
        nil -> current
        field -> Map.put_new(current, field, flush_buffer(buffer))
      end

    {:ok, %{state | current: current, char_buf: nil}}
  end

  def handle_event(:end_element, _name, state), do: {:ok, %{state | char_buf: nil}}

  @impl Saxy.Handler
  def handle_event(:cdata, chars, %{char_buf: buffer} = state) when is_list(buffer) do
    {:ok, %{state | char_buf: [chars | buffer]}}
  end

  def handle_event(:cdata, _chars, state), do: {:ok, state}

  defp attr(attrs, key) do
    case Enum.find(attrs, fn {name, _value} -> name == key end) do
      {_name, value} -> value
      nil -> nil
    end
  end

  defp field_for_element("title"), do: :title
  defp field_for_element("sub-title"), do: :sub_title
  defp field_for_element("desc"), do: :description
  defp field_for_element("category"), do: :category
  defp field_for_element("episode-num"), do: :episode_num
  defp field_for_element(_name), do: nil

  defp flush_buffer(buffer) do
    buffer
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> String.trim()
    |> empty_to_nil()
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  # XMLTV datetime: "20260503040000 -0300" or "20260503040000".
  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case Regex.run(
           ~r/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-])(\d{2})(\d{2}))?$/,
           String.trim(value)
         ) do
      [_, year, month, day, hour, minute, second] ->
        build_datetime(year, month, day, hour, minute, second, 0)

      [_, year, month, day, hour, minute, second, sign, offset_hour, offset_minute] ->
        offset_seconds =
          (String.to_integer(offset_hour) * 3600 + String.to_integer(offset_minute) * 60) *
            sign_multiplier(sign)

        build_datetime(year, month, day, hour, minute, second, offset_seconds)

      _no_match ->
        nil
    end
  end

  defp build_datetime(year, month, day, hour, minute, second, offset_seconds) do
    case NaiveDateTime.new(
           String.to_integer(year),
           String.to_integer(month),
           String.to_integer(day),
           String.to_integer(hour),
           String.to_integer(minute),
           String.to_integer(second)
         ) do
      {:ok, naive} ->
        naive
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.add(-offset_seconds, :second)

      {:error, _reason} ->
        nil
    end
  end

  defp sign_multiplier("-"), do: -1
  defp sign_multiplier(_sign), do: 1
end
