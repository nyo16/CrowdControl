defmodule Sandboxd.Router do
  @moduledoc """
  The `sandboxd` v1 HTTP protocol — seven routes, one sandbox.

  | Method | Path | Body / Query | Notes |
  |---|---|---|---|
  | `GET` | `/v1/health` | — | readiness; the only unauthenticated route, and it returns no state |
  | `POST` | `/v1/exec` | `{executable, args, env}` | one exec per sandbox lifetime; second call is `409` |
  | `POST` | `/v1/stdin` | `{data: base64}` | appends to the live process's stdin |
  | `GET` | `/v1/stream` | `?offset=N` | chunked bytes from a 0-indexed byte offset |
  | `GET` | `/v1/status` | `?wait_ms=N` | `{alive, exit_status, bytes}`, long-polled |
  | `PUT` | `/v1/files/*path` | raw bytes, `?mode=0600` | writes inside the sandbox |
  | `POST` | `/v1/shutdown` | — | kills the CLI; the *sandbox* is the provider's to destroy |

  ## Why `/v1/health` returns nothing but `{"ok": true}`

  It is unauthenticated, because a provider has to poll it before it can know
  the agent is up, and it is polled by definition before any token round trip
  has succeeded. So it must leak nothing: no exec state, no byte counts, no
  version, no capture path. Anything that can reach the port learns only that
  something is listening.

  ## Env arrives in the request body

  `POST /v1/exec` takes `env` as a JSON object, never as query parameters,
  because query strings land in access logs and proxy logs. Nothing in this
  module logs a request body.

  ## Offsets are 0-indexed

  `/v1/stream?offset=N` returns bytes from N onward, N being the count of bytes
  the caller already has. `tail -c +N` is 1-indexed and the resulting `+ 1` in
  `CrowdControl.Backend.Docker` is a documented hazard; there is no shell here,
  so the hazard is simply absent. Do not reintroduce a 1-indexed cursor.
  """

  use Plug.Router

  alias Sandboxd.Capture
  alias Sandboxd.Exec

  @max_body 8 * 1024 * 1024
  @max_file_body 32 * 1024 * 1024
  @max_wait_ms 60_000

  plug(:fetch_query_params)
  plug(:match)

  # Health is matched before auth so readiness polling needs no credential;
  # every other route is behind Sandboxd.Auth. Ordering is the entire security
  # property here, so it is asserted directly in the test suite.
  plug(:skip_auth_for_health)

  # pass: ["*/*"] because PUT /v1/files carries raw bytes of any content type
  # and must reach read_body/2 unparsed. Only JSON is ever decoded into params.
  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: @max_body
  )

  plug(:dispatch)

  get "/v1/health" do
    json(conn, 200, %{ok: true})
  end

  post "/v1/exec" do
    with {:ok, executable} <- fetch_string(conn.params, "executable"),
         {:ok, args} <- fetch_args(conn.params),
         {:ok, env} <- fetch_env(conn.params) do
      case Exec.exec(executable, args, env) do
        :ok ->
          json(conn, 200, %{ok: true})

        {:error, :already_executed} ->
          json(conn, 409, %{error: "already_executed"})

        {:error, reason} ->
          json(conn, 500, %{error: "exec_failed", reason: inspect(reason)})
      end
    else
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  post "/v1/stdin" do
    with {:ok, encoded} <- fetch_string(conn.params, "data"),
         {:ok, data} <- decode_base64(encoded) do
      case Exec.write(data) do
        :ok -> json(conn, 200, %{ok: true})
        {:error, :not_started} -> json(conn, 409, %{error: "not_started"})
        {:error, reason} -> json(conn, 500, %{error: "write_failed", reason: inspect(reason)})
      end
    else
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  get "/v1/stream" do
    case parse_non_neg(conn.query_params["offset"] || "0") do
      {:ok, offset} -> stream_capture(conn, offset)
      :error -> json(conn, 400, %{error: "offset must be a non-negative integer"})
    end
  end

  get "/v1/status" do
    case parse_wait_ms(conn.query_params["wait_ms"]) do
      {:ok, wait_ms} ->
        status = Exec.status()

        # Long-poll on the byte count the caller already has, so a caller that
        # is up to date parks instead of spinning. A caller with no ?wait_ms
        # gets the current status immediately.
        status =
          if wait_ms > 0 and status.alive do
            _ = Capture.await(status.bytes, wait_ms)
            Exec.status()
          else
            status
          end

        json(conn, 200, %{
          alive: status.alive,
          exit_status: status.exit_status,
          bytes: status.bytes,
          started: status.started
        })

      :error ->
        json(conn, 400, %{error: "wait_ms must be an integer between 0 and #{@max_wait_ms}"})
    end
  end

  put "/v1/files/*path" do
    with {:ok, target} <- safe_path(path),
         {:ok, mode} <- parse_mode(conn.query_params["mode"]),
         {:ok, body, conn} <- read_full_body(conn) do
      case write_file(target, body, mode) do
        :ok -> json(conn, 200, %{ok: true, path: target, bytes: byte_size(body)})
        {:error, reason} -> json(conn, 500, %{error: "write_failed", reason: inspect(reason)})
      end
    else
      {:error, :body_too_large} -> json(conn, 413, %{error: "body_too_large"})
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  post "/v1/shutdown" do
    :ok = Exec.shutdown()
    conn = json(conn, 200, %{ok: true})

    # Halt *after* the response is on the wire. Teardown of the sandbox itself
    # is the provider's job; this only stops the agent and its CLI.
    spawn(fn ->
      Process.sleep(100)
      System.stop(0)
    end)

    conn
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  # --- Plugs ---

  @doc false
  def skip_auth_for_health(%Plug.Conn{request_path: "/v1/health"} = conn, _opts), do: conn
  def skip_auth_for_health(conn, _opts), do: Sandboxd.Auth.call(conn, [])

  # --- Streaming ---

  defp stream_capture(conn, offset) do
    conn =
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_chunked(200)

    Capture.stream(offset)
    |> Enum.reduce_while(conn, fn chunk, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} ->
          {:cont, conn}

        {:error, _reason} ->
          # The client vanished or cancelled mid-stream, which is a normal and
          # frequent event: the parent app cancels the stream deliberately at
          # its backpressure watermark and re-requests from a new offset.
          {:halt, conn}
      end
    end)
  end

  # --- Param handling ---

  defp fetch_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required and must be a non-empty string"}
    end
  end

  defp fetch_args(params) do
    case Map.get(params, "args", []) do
      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1) do
          {:ok, args}
        else
          {:error, "args must be a list of strings"}
        end

      _ ->
        {:error, "args must be a list of strings"}
    end
  end

  defp fetch_env(params) do
    case Map.get(params, "env", %{}) do
      env when is_map(env) ->
        if Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          {:ok, env}
        else
          {:error, "env must be an object of string keys to string values"}
        end

      _ ->
        {:error, "env must be an object of string keys to string values"}
    end
  end

  defp decode_base64(encoded) do
    case Base.decode64(encoded) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, "data must be base64"}
    end
  end

  defp parse_non_neg(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_wait_ms(nil), do: {:ok, 0}

  defp parse_wait_ms(value) do
    case parse_non_neg(value) do
      {:ok, ms} when ms <= @max_wait_ms -> {:ok, ms}
      _ -> :error
    end
  end

  # Modes arrive as octal text ("0600"), because that is how a caller thinks
  # about them and how the provider's own docs write them.
  defp parse_mode(nil), do: {:ok, 0o600}

  defp parse_mode(value) do
    case Integer.parse(value, 8) do
      {mode, ""} when mode >= 0 and mode <= 0o777 -> {:ok, mode}
      _ -> {:error, "mode must be octal, e.g. 0600"}
    end
  end

  # --- File writes ---

  @doc false
  # Path traversal is rejected here rather than sanitized. A request for
  # `/v1/files/../../etc/passwd` is not a request to be helpfully normalized;
  # it is a request to be refused, because a caller with a legitimate absolute
  # path never needs `..` to express it. Plug splits the wildcard into segments,
  # so the check is on segments, not on a reassembled string that could be
  # re-split differently later.
  def safe_path(segments) when is_list(segments) do
    cond do
      segments == [] ->
        {:error, "path is required"}

      Enum.any?(segments, &(&1 in ["..", "."])) ->
        {:error, "path must not contain . or .. segments"}

      Enum.any?(segments, &String.contains?(&1, "\0")) ->
        {:error, "path must not contain null bytes"}

      true ->
        {:ok, "/" <> Enum.join(segments, "/")}
    end
  end

  defp read_full_body(conn), do: read_full_body(conn, [], 0)

  defp read_full_body(conn, acc, size) do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, chunk, conn} ->
        total = size + byte_size(chunk)

        if total > @max_file_body do
          {:error, :body_too_large}
        else
          {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
        end

      {:more, chunk, conn} ->
        total = size + byte_size(chunk)

        if total > @max_file_body do
          {:error, :body_too_large}
        else
          read_full_body(conn, [chunk | acc], total)
        end

      {:error, reason} ->
        {:error, "could not read body: #{inspect(reason)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_file(target, body, mode) do
    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(target, body),
         :ok <- File.chmod(target, mode) do
      :ok
    end
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(payload))
  end
end
