defmodule Observe.Datasources.Prometheus do
  @moduledoc """
  Minimal Prometheus HTTP API adapter.
  """

  def execute(datasource, request) do
    with {:ok, url} <- required(datasource, "url"),
         {:ok, query} <- required(request, "query"),
         {:ok, response} <- run_request(url, datasource, request, query),
         {:ok, body} <- decode_response(response) do
      {:ok, rows(body)}
    end
  end

  def label_values(%{"mode" => "real"} = datasource, spec) do
    with {:ok, url} <- required(datasource, "url"),
         {:ok, label} <- required(spec, "metric_label"),
         {:ok, response} <- run_label_values_request(url, datasource, spec, label),
         {:ok, body} <- decode_response(response) do
      {:ok, get_in(body, ["data"]) || []}
    end
  end

  def label_values(_datasource, _spec), do: {:ok, []}

  defp run_label_values_request(url, datasource, spec, label) do
    params = label_values_params(spec)

    options =
      [params: params, receive_timeout: Map.get(datasource, "timeout_ms", 15_000)]
      |> maybe_put_auth(datasource)

    case Req.get(prometheus_url(url, "label/#{URI.encode(label)}/values"), options) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, "Prometheus request failed: #{Exception.message(reason)}"}
    end
  end

  defp label_values_params(%{"metric" => metric}) when is_binary(metric) and metric != "" do
    [{:"match[]", metric}]
  end

  defp label_values_params(_spec), do: []

  defp run_request(url, datasource, request, query) do
    endpoint = if range_request?(request), do: "query_range", else: "query"
    params = request_params(request, query)

    options =
      [params: params, receive_timeout: Map.get(datasource, "timeout_ms", 15_000)]
      |> maybe_put_auth(datasource)

    case Req.get(prometheus_url(url, endpoint), options) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, "Prometheus request failed: #{Exception.message(reason)}"}
    end
  end

  defp request_params(request, query) do
    base = [query: query]

    cond do
      explicit_range_request?(request) ->
        base ++ [start: request["start"], end: request["end"], step: request["step"]]

      Map.get(request, "range") ->
        now = DateTime.utc_now()

        start =
          Map.get(request, "start") || now |> DateTime.add(-10_800, :second) |> DateTime.to_unix()

        end_time = Map.get(request, "end") || DateTime.to_unix(now)
        step = Map.get(request, "step") || Map.get(request, "interval") || "1m"
        base ++ [start: start, end: end_time, step: step]

      true ->
        maybe_put(base, :time, request["time"])
    end
  end

  defp range_request?(request) do
    explicit_range_request?(request) || Map.get(request, "range")
  end

  defp explicit_range_request?(request), do: request["start"] && request["end"] && request["step"]

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)

  defp maybe_put_auth(options, %{
         "basic_auth" => %{"username" => username, "password" => password}
       })
       when username != "" and password != "" do
    Keyword.put(options, :auth, {:basic, "#{username}:#{password}"})
  end

  defp maybe_put_auth(options, _datasource), do: options

  defp prometheus_url(url, endpoint) do
    url
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/v1/#{endpoint}")
  end

  defp decode_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    case body do
      %{"status" => "success"} -> {:ok, body}
      %{"error" => error} -> {:error, "Prometheus returned error: #{error}"}
      _ -> {:error, "Prometheus returned an unexpected response"}
    end
  end

  defp decode_response(%Req.Response{status: status, body: body}) do
    {:error, "Prometheus returned HTTP #{status}: #{inspect(body)}"}
  end

  defp rows(%{"data" => %{"resultType" => "vector", "result" => result}}) do
    Enum.map(result, fn item ->
      item
      |> metric_labels()
      |> Map.merge(sample_value(item["value"]))
    end)
  end

  defp rows(%{"data" => %{"resultType" => "matrix", "result" => result}}) do
    Enum.flat_map(result, fn item ->
      labels = metric_labels(item)

      item
      |> Map.get("values", [])
      |> Enum.map(&Map.merge(labels, sample_value(&1)))
    end)
  end

  defp rows(%{"data" => %{"resultType" => "scalar", "result" => sample}}) do
    [sample_value(sample)]
  end

  defp rows(_body), do: []

  defp metric_labels(item), do: Map.get(item, "metric", %{})

  defp sample_value([time, value]) do
    %{"time" => time, "value" => parse_number(value), "raw_value" => value}
  end

  defp sample_value(_value), do: %{"value" => nil}

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp parse_number(value), do: value

  defp required(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Prometheus #{key} is required"}
    end
  end
end
