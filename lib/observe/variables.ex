defmodule Observe.Variables do
  @moduledoc """
  Resolves dashboard variables and interpolates `${vars.name}` and `${inputs.name}` placeholders.
  """

  alias Observe.Datasources.Prometheus

  @var_placeholder ~r/\$\{vars\.([A-Za-z0-9_\-]+)((?:\.[A-Za-z0-9_\-]+)*)\}/
  @input_placeholder ~r/\$\{inputs\.([A-Za-z0-9_\-]+)\}/
  @env_placeholder ~r/\$\{env\.([A-Za-z0-9_]+)\}/

  def defaults(variables, datasources \\ %{}) do
    variables
    |> ordered_variables()
    |> Enum.reduce(%{}, fn {name, spec}, acc ->
      values = options(spec, datasources, acc)
      default = Map.get(spec, "default")

      value =
        cond do
          values == [] -> default
          default in values -> default
          true -> List.first(values)
        end

      Map.put(acc, name, value)
    end)
  end

  def merge(variables, params, datasources \\ %{}) do
    defaults = defaults(variables, datasources)

    requested = Map.merge(defaults, params)

    variables
    |> ordered_variables()
    |> Enum.reduce(defaults, fn {name, _spec}, acc ->
      default = Map.get(defaults, name)
      value = Map.get(requested, name, default)
      spec = Map.get(variables, name, %{})
      values = options(spec, datasources, Map.merge(requested, acc))

      selected_value =
        cond do
          values == [] -> value
          value in values -> value
          default in values -> default
          true -> List.first(values)
        end

      Map.put(acc, name, selected_value)
    end)
  end

  def context(variables, values, datasources \\ %{}) do
    Map.new(values, fn {name, value} ->
      spec = Map.get(variables, name, %{})
      {name, variable_context(value, spec, datasources)}
    end)
  end

  def options(spec, datasources) do
    options(spec, datasources, %{})
  end

  def options(spec, datasources, vars) do
    spec
    |> select_options(datasources, vars)
    |> Enum.map(fn {_label, value} -> value end)
  end

  def select_options(%{"type" => "datasource"} = spec, datasources) do
    select_options(spec, datasources, %{})
  end

  def select_options(spec, datasources) do
    select_options(spec, datasources, %{})
  end

  def select_options(%{"type" => "datasource"} = spec, datasources, _vars) do
    datasource_type = Map.get(spec, "datasource_type")
    matcher = variable_matcher(spec)

    datasources
    |> Enum.filter(fn {_name, config} ->
      is_nil(datasource_type) or Map.get(config, "type") == datasource_type
    end)
    |> Enum.map(fn {name, _config} -> {option_label(name, matcher, spec), name} end)
    |> Enum.reject(fn {label, _value} -> is_nil(label) end)
    |> Enum.sort_by(fn {label, _value} -> label end)
  end

  def select_options(%{"type" => "label_values"} = spec, datasources, vars) do
    matcher = variable_matcher(spec)

    spec
    |> label_values(datasources, vars)
    |> Enum.map(fn value -> {option_label(to_string(value), matcher, spec), value} end)
    |> Enum.reject(fn {label, _value} -> is_nil(label) end)
  end

  def select_options(spec, _datasources, _vars) do
    matcher = variable_matcher(spec)

    spec
    |> Map.get("values", [])
    |> Enum.map(fn value -> {option_label(to_string(value), matcher, spec), value} end)
    |> Enum.reject(fn {label, _value} -> is_nil(label) end)
  end

  def interpolate(value, vars, inputs \\ %{})

  def interpolate(value, vars, inputs) when is_binary(value) do
    value
    |> replace_vars(vars)
    |> replace_inputs(inputs)
    |> replace_env()
  end

  def interpolate(value, vars, inputs) when is_map(value) do
    Map.new(value, fn {key, val} -> {key, interpolate(val, vars, inputs)} end)
  end

  def interpolate(value, vars, inputs) when is_list(value),
    do: Enum.map(value, &interpolate(&1, vars, inputs))

  def interpolate(value, _vars, _inputs), do: value

  defp replace_vars(value, vars) do
    Regex.replace(@var_placeholder, value, fn _match, name, path ->
      vars
      |> variable_value(name, path)
      |> to_string()
    end)
  end

  defp label_values(spec, datasources, vars) do
    datasource_ref = spec |> Map.get("datasource") |> interpolate(vars)

    case Map.get(datasources, datasource_ref) do
      %{"type" => "prometheus"} = datasource ->
        case Prometheus.label_values(datasource, spec) do
          {:ok, values} -> values
          {:error, _reason} -> []
        end

      _datasource ->
        []
    end
  end

  defp ordered_variables(variables) do
    Enum.sort_by(variables, fn {_name, spec} ->
      if Map.get(spec, "type") == "label_values", do: 1, else: 0
    end)
  end

  defp replace_inputs(value, inputs) do
    Regex.replace(@input_placeholder, value, fn _match, name ->
      to_string(Map.get(inputs, name, ""))
    end)
  end

  defp replace_env(value) do
    Regex.replace(@env_placeholder, value, fn _match, name -> System.get_env(name, "") end)
  end

  defp variable_matcher(spec) do
    matcher = Map.get(spec, "match") || Map.get(spec, "filter") || Map.get(spec, "name_regex")

    case matcher do
      value when is_binary(value) and value != "" ->
        value |> strip_regex_slashes() |> Regex.compile()

      _value ->
        nil
    end
  end

  defp option_label(value, nil, spec), do: extracted_label(value, [value], spec)

  defp option_label(value, {:ok, regex}, spec) do
    case Regex.run(regex, value) do
      nil -> nil
      captures -> extracted_label(value, captures, spec)
    end
  end

  defp option_label(_value, {:error, _reason}, _spec), do: nil

  defp variable_context(value, spec, datasources) do
    captures = variable_captures(value, spec)

    %{
      "value" => value,
      "label" => extracted_label(value, captures, spec),
      "formats" => variable_formats(captures, spec),
      "options" => select_options(spec, datasources)
    }
  end

  defp variable_captures(value, spec) do
    case variable_matcher(spec) do
      {:ok, regex} -> Regex.run(regex, to_string(value)) || [to_string(value)]
      _matcher -> [to_string(value)]
    end
  end

  defp variable_formats(captures, spec) do
    spec
    |> Map.get("formats", %{})
    |> case do
      formats when is_map(formats) ->
        Map.new(formats, fn {name, format} ->
          {name, if(is_binary(format), do: replace_captures(format, captures), else: format)}
        end)

      _formats ->
        %{}
    end
  end

  defp variable_value(vars, name, "") do
    case Map.get(vars, name) do
      %{} = context -> Map.get(context, "value", "")
      value -> value || ""
    end
  end

  defp variable_value(vars, name, path) do
    case Map.get(vars, name) do
      %{} = context -> get_in(context, String.split(String.trim_leading(path, "."), ".")) || ""
      _value -> ""
    end
  end

  defp extracted_label(name, captures, spec) do
    case Map.get(spec, "label") || Map.get(spec, "extract") do
      label when is_binary(label) and label != "" -> replace_captures(label, captures)
      _extract -> name
    end
  end

  defp replace_captures(value, captures) do
    Regex.replace(~r/\$(\d+)/, value, fn _match, index ->
      captures |> Enum.at(String.to_integer(index)) |> to_string()
    end)
  end

  defp strip_regex_slashes("/" <> value) do
    if String.ends_with?(value, "/"), do: String.slice(value, 0..-2//1), else: "/" <> value
  end

  defp strip_regex_slashes(value), do: value
end
