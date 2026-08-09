defmodule CrowdControl.FakeOpenAIServer do
  @moduledoc false
  # A stand-in for a vLLM (or any OpenAI-compatible) server, used by the
  # `:omp` integration test to prove that a generated `models.yml` really does
  # route a session at a custom endpoint.
  #
  # Raw `:gen_tcp` rather than a web framework: the suite has no server
  # dependency, and the two routes needed here are a handful of lines. Same
  # spirit as `fake_cli.sh` -- fake the external thing, keep the test hermetic.
  #
  #     {:ok, server} = FakeOpenAIServer.start_link(model: "my-model")
  #     FakeOpenAIServer.base_url(server)   # => "http://127.0.0.1:54321/v1"
  #     FakeOpenAIServer.requests(server)   # => [{"/v1/models", auth_header}, ...]

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @spec base_url(pid()) :: String.t()
  def base_url(server), do: GenServer.call(server, :base_url)

  @doc "Every request seen so far, oldest first, as `{path, authorization_header}`."
  @spec requests(pid()) :: [{String.t(), String.t() | nil}]
  def requests(server), do: GenServer.call(server, :requests)

  @impl true
  def init(opts) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    state = %{listen: listen, port: port, requests: [], opts: opts}

    {:ok, state, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, state) do
    parent = self()
    spawn_link(fn -> accept_loop(state.listen, parent, state.opts) end)
    {:noreply, state}
  end

  @impl true
  def handle_call(:base_url, _from, state),
    do: {:reply, "http://127.0.0.1:#{state.port}/v1", state}

  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

  @impl true
  def handle_info({:request, path, auth}, state),
    do: {:noreply, %{state | requests: [{path, auth} | state.requests]}}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  # --- acceptor ---

  defp accept_loop(listen, parent, opts) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, parent, opts) end)
        accept_loop(listen, parent, opts)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, parent, opts) do
    with {:ok, {method_path, headers, body}} <- read_request(socket) do
      [_method, path | _] = String.split(method_path, " ")
      auth = headers["authorization"]
      send(parent, {:request, path, auth})

      respond(socket, route(path, body, auth, opts))
    end

    :gen_tcp.close(socket)
  end

  # Reads headers, then exactly Content-Length bytes. Enough for the two JSON
  # POSTs omp makes; no chunked-encoding support and none needed.
  defp read_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data

        case String.split(acc, "\r\n\r\n", parts: 2) do
          [head, body] ->
            [request_line | header_lines] = String.split(head, "\r\n")
            headers = parse_headers(header_lines)
            length = String.to_integer(Map.get(headers, "content-length", "0"))
            {:ok, body} = read_body(socket, body, length)
            {:ok, {request_line, headers, body}}

          [_partial] ->
            read_request(socket, acc)
        end

      {:error, _reason} ->
        :error
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: {:ok, body}

  defp read_body(socket, body, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, more} -> read_body(socket, body <> more, length)
      {:error, _} -> {:ok, body}
    end
  end

  defp parse_headers(lines) do
    Map.new(lines, fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> {String.downcase(key), String.trim(value)}
        [key] -> {String.downcase(key), ""}
      end
    end)
  end

  defp route(path, body, auth, opts) do
    required = opts[:api_key]

    cond do
      required && auth != "Bearer #{required}" ->
        {401, "application/json", ~s({"error":"unauthorized"})}

      String.ends_with?(path, "/models") ->
        {200, "application/json", models_body(opts)}

      String.ends_with?("#{path}", "/chat/completions") ->
        {200, "text/event-stream", completion_stream(body, opts)}

      true ->
        {404, "text/plain", "not found"}
    end
  end

  defp models_body(opts) do
    JSON.encode!(%{
      "object" => "list",
      "data" => [
        %{
          "id" => model(opts),
          "object" => "model",
          "owned_by" => "vllm",
          "max_model_len" => 32_768
        }
      ]
    })
  end

  # Streams the prompt back as `echo: <prompt>` in OpenAI SSE chunk shape, so
  # the assertion can tie the reply to the request that produced it.
  defp completion_stream(body, opts) do
    prompt =
      case JSON.decode(body) do
        {:ok, %{"messages" => messages}} when is_list(messages) -> last_user_text(messages)
        _ -> ""
      end

    reply = "echo: #{prompt}"

    chunks = [
      chunk(%{"role" => "assistant", "content" => ""}, nil, opts),
      chunk(%{"content" => reply}, nil, opts),
      chunk(%{}, "stop", opts)
    ]

    Enum.join(chunks) <> "data: [DONE]\n\n"
  end

  defp last_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(%{}, &(is_map(&1) and &1["role"] == "user"))
    |> Map.get("content")
    |> text_of()
  end

  defp text_of(content) when is_binary(content), do: content

  defp text_of(content) when is_list(content),
    do: Enum.map_join(content, "", &if(is_map(&1), do: to_string(&1["text"]), else: ""))

  defp text_of(_content), do: ""

  defp chunk(delta, finish, opts) do
    payload =
      JSON.encode!(%{
        "id" => "cmpl-1",
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model(opts),
        "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]
      })

    "data: #{payload}\n\n"
  end

  defp model(opts), do: Keyword.get(opts, :model, "fake/vllm-model")

  defp respond(socket, {status, content_type, body}) do
    head =
      "HTTP/1.1 #{status} #{reason(status)}\r\n" <>
        "content-type: #{content_type}\r\n" <>
        "content-length: #{byte_size(body)}\r\n" <>
        "connection: close\r\n\r\n"

    :gen_tcp.send(socket, head <> body)
  end

  defp reason(200), do: "OK"
  defp reason(401), do: "Unauthorized"
  defp reason(404), do: "Not Found"
end
