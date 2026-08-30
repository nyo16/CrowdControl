defmodule CrowdControl.K8sFakeServer do
  @moduledoc false
  # A real TLS listener that speaks just enough of the Kubernetes
  # `pods/{name}/exec` websocket protocol for a test to *script* the outcome:
  # a rejected upgrade, v4 channel frames, or a mid-stream connection drop.
  #
  # ## Why this is not a `:req_adapter` stub
  #
  # `CrowdControl.Backend.Kubernetes.API.client/2` accepts a `:req_adapter`, and
  # every plain `Kubereq.get/create/delete/list` call is fully expressible
  # through it. The websocket paths are not, and cannot be made so.
  # `Req.merge/2` lists `:adapter` in `request_option_names` and assigns it
  # straight onto the `%Req.Request{}` struct (req.ex:544) -- and every
  # `:connect` operation sets it **last**: `Kubereq.Connect.start_link/4`
  # (connect.ex:141), `Kubereq.exec/4` (kubereq.ex:1292) and `Kubereq.logs/4`
  # (kubereq.ex:1181). Last writer wins and kubereq is always last, so an
  # adapter installed by a test is *silently discarded* on exec and log
  # requests: the stub never runs, `Kubereq.Connect.connect/1` calls
  # `Mint.HTTP.connect/4` against the kubeconfig's real `server`, and the test
  # passes or fails for reasons that have nothing to do with what it stubbed.
  # `Kubereq.Kubeconfig.Stub` does not help either -- it manufactures a cluster
  # carrying a `:plug`, which is a Req *option*, and the `:connect` path never
  # reaches Req's plug step.
  #
  # So a real socket is the only seam that exercises `Connect.start_link/4` and
  # `Mint.WebSocket.upgrade/5` at all. Do not replace this listener with an
  # adapter stub; it has been tried, and the result is a test that cannot fail.
  #
  # ## Scripting
  #
  # One script per connection, consumed in order and served one connection at a
  # time. Connections past the end of the queue get the default script — accept,
  # no frames, graceful close. Each script is a keyword list:
  #
  #   * `:status` -- HTTP status for the upgrade response. `101` (the default)
  #     accepts; anything else rejects with an empty body, which is what
  #     `Mint.WebSocket.new/5` turns into `%Mint.WebSocket.UpgradeFailureError{}`.
  #   * `:subprotocol` -- echoed back in `sec-websocket-protocol` on a 101.
  #   * `:frames` -- sent after the upgrade, in order. `{:stdout, data}`,
  #     `{:stderr, data}` and `{:status, data}` are v4 channels 1, 2 and 3;
  #     `{:sleep, ms}` spaces frames out so a following `:abort` cannot land in
  #     the same `Mint.WebSocket.stream/2` call (kubereq's
  #     `Connect.handle_info/2` discards buffered responses alongside a
  #     transport error).
  #   * `:finish` -- `:close` (default) sends a 1000 close frame; `:abort` drops
  #     the TCP connection with no close frame, which the client sees as
  #     `%Mint.TransportError{reason: :closed}`.
  #
  #     {:ok, server} = start_supervised({K8sFakeServer, scripts: [[status: 404]]})
  #     API.open_exec(K8sFakeServer.config(server), "cc-x", ["true"], self())
  #     # => {:error, {:k8s, {:upgrade_failed, 404}}}

  use GenServer

  # RFC 6455's magic GUID. `Mint.WebSocket.new/5` verifies the accept nonce
  # (web_socket.ex:355), so a listener that skips this never reaches a frame.
  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # Scripted frames wait this long after the upgrade response, so they land in a
  # `recv` of their own rather than in the one that swallows the priming frame
  # (see `accept_upgrade/3`). Nothing in the protocol acknowledges an upgrade —
  # kubereq sends nothing until it has stdin to send — so a settling window is
  # the only separator available. The client is already blocked in
  # `:ssl.recv/3` when the response lands, so this is three orders of magnitude
  # more than it needs on loopback.
  @settle_ms 50

  @type frame ::
          {:stdout | :stderr | :status, binary()}
          | {:sleep, non_neg_integer()}

  @type script :: [
          status: pos_integer(),
          subprotocol: String.t(),
          frames: [frame()],
          finish: :close | :abort
        ]

  @doc """
  Start a listener on an ephemeral loopback port.

  Options: `:scripts` (see the module comment), and `:user` -- either a
  kubeconfig user map such as `%{"token" => "..."}` or the atom `:client_cert`,
  which builds a `client-certificate-data`/`client-key-data` user from the
  listener's own keypair so that a test can prove TLS material never reaches an
  error term.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "The port the listener bound to."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "A kubeconfig whose current cluster is this listener, verification off."
  @spec kubeconfig(GenServer.server()) :: Kubereq.Kubeconfig.t()
  def kubeconfig(server), do: GenServer.call(server, :kubeconfig)

  @doc "An `API.config()` pointed at this listener."
  @spec config(GenServer.server()) :: keyword()
  def config(server), do: [kubeconfig: kubeconfig(server)]

  @doc "Append a script for the next unscripted connection."
  @spec script(GenServer.server(), script()) :: :ok
  def script(server, script), do: GenServer.call(server, {:script, script})

  @doc """
  Every request head received so far, oldest first, verbatim off the socket.

  This is the part no adapter stub can produce: proof that the query string and
  headers the backend built actually reached a wire.
  """
  @spec requests(GenServer.server()) :: [String.t()]
  def requests(server), do: GenServer.call(server, :requests)

  @impl true
  def init(opts) do
    {:ok, _started} = Application.ensure_all_started(:ssl)
    tls = tls_material()

    {:ok, listen} =
      :ssl.listen(0,
        mode: :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        cert: tls[:cert],
        key: tls[:key]
      )

    {:ok, {_ip, port}} = :ssl.sockname(listen)

    state = %{
      listen: listen,
      port: port,
      kubeconfig: build_kubeconfig(port, build_user(opts[:user] || %{}, tls)),
      scripts: Keyword.get(opts, :scripts, []),
      requests: []
    }

    {:ok, state, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, state) do
    server = self()
    spawn_link(fn -> accept_loop(state.listen, server) end)
    {:noreply, state}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:kubeconfig, _from, state), do: {:reply, state.kubeconfig, state}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

  def handle_call({:script, script}, _from, state),
    do: {:reply, :ok, %{state | scripts: state.scripts ++ [script]}}

  # Records the request and hands back this connection's script in one round
  # trip, so a request is always recorded before its response is written and
  # `requests/1` can never miss the connection a test just observed.
  #
  # A drained queue falls back to the default script — accept, no frames,
  # graceful close — rather than replaying the last one, so an unexpected
  # reconnect shows up as an immediate close instead of a second connection
  # drop, and `script/2` after a drain scripts the *next* connection.
  def handle_call({:connection, raw}, _from, state) do
    {script, scripts} =
      case state.scripts do
        [] -> {[], []}
        [head | tail] -> {head, tail}
      end

    {:reply, script, %{state | scripts: scripts, requests: [raw | state.requests]}}
  end

  @impl true
  def terminate(_reason, state) do
    :ssl.close(state.listen)
  end

  # --- acceptor ---

  # One connection at a time, served to completion in the accepting process:
  # every exec path opens exactly one connection, and serving it inline keeps
  # socket ownership in one place. A `{:sleep, _}` frame therefore delays the
  # *next* connection too, which is why sleeps stay small.
  defp accept_loop(listen, server) do
    with {:ok, socket} <- :ssl.transport_accept(listen),
         {:ok, tls} <- :ssl.handshake(socket, 5_000) do
      serve(tls, server)
      accept_loop(listen, server)
    else
      # The listener is gone: the test that owned it has finished.
      {:error, :closed} -> :ok
      {:error, _handshake_failed} -> accept_loop(listen, server)
    end
  end

  defp serve(socket, server) do
    case read_head(socket) do
      {:ok, raw} -> run(socket, headers(raw), GenServer.call(server, {:connection, raw}))
      :error -> :ssl.close(socket)
    end
  end

  defp run(socket, headers, script) do
    case Keyword.get(script, :status, 101) do
      101 ->
        accept_upgrade(socket, headers, script[:subprotocol])
        Process.sleep(@settle_ms)
        Enum.each(Keyword.get(script, :frames, []), &send_frame(socket, &1))
        finish(socket, Keyword.get(script, :finish, :close))

      status ->
        reject_upgrade(socket, status)
        :ssl.close(socket)
    end
  end

  # The priming frame goes out in the *same write* as the upgrade response on
  # purpose. The apiserver writes an empty frame on the lowest writable channel
  # as soon as the stream exists (websocket.go:100-109) and kubereq loses it:
  # mint treats a 101 as body-mode `:single` (http1.ex:1087), so every byte
  # arriving in the same `recv` as the response is emitted as a body part, and
  # `Connect.receive_upgrade_response/3` keeps only `:status` and `:headers`.
  # Measured against a real cluster: swallowed on 24 of 25 upgrades. Coalescing
  # it here reproduces that exactly, and gives the scripted frames a sacrificial
  # victim instead of letting one become it.
  defp accept_upgrade(socket, headers, subprotocol) do
    accept = Base.encode64(:crypto.hash(:sha, headers["sec-websocket-key"] <> @ws_guid))

    :ssl.send(socket, [
      "HTTP/1.1 101 Switching Protocols\r\n",
      "upgrade: websocket\r\n",
      "connection: Upgrade\r\n",
      "sec-websocket-accept: ",
      accept,
      "\r\n",
      if(subprotocol, do: ["sec-websocket-protocol: ", subprotocol, "\r\n"], else: []),
      "\r\n",
      binary_frame(<<channel(:stdout)>>)
    ])
  end

  # `content-length: 0` rather than the API server's `connection: close`, so
  # Mint sees `:done` without waiting for a FIN. Only the status is under test:
  # `%Mint.WebSocket.UpgradeFailureError{}` carries the status and headers, and
  # never the body.
  defp reject_upgrade(socket, status) do
    :ssl.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " Fake\r\ncontent-length: 0\r\n\r\n"
    ])
  end

  defp send_frame(_socket, {:sleep, ms}), do: Process.sleep(ms)

  defp send_frame(socket, {stream, payload}) do
    :ssl.send(socket, binary_frame(<<channel(stream)>> <> payload))
  end

  # v4 channel framing: one channel byte, then the raw payload
  # (apimachinery/pkg/util/httpstream/wsstream/conn.go, `Conn.write`).
  defp channel(:stdout), do: 1
  defp channel(:stderr), do: 2
  defp channel(:status), do: 3

  # Server-to-client frames are never masked (RFC 6455 5.1), so the payload
  # follows the length directly. FIN + binary opcode = 0x82.
  defp binary_frame(payload) when byte_size(payload) < 126,
    do: [<<0x82, byte_size(payload)::8>>, payload]

  defp binary_frame(payload) when byte_size(payload) < 65_536,
    do: [<<0x82, 126::8, byte_size(payload)::16>>, payload]

  # A bounded wait for the peer to drop its end, so the close frame is never
  # racing a FIN of our own. kubereq stops the channel on a close frame and
  # never answers it, so this returns `{:error, :closed}` as soon as that
  # process dies.
  defp finish(socket, :close) do
    :ssl.send(socket, <<0x88, 2::8, 1000::16>>)
    :ssl.recv(socket, 0, 1_000)
    :ssl.close(socket)
  end

  defp finish(socket, :abort), do: :ssl.close(socket)

  # `pods/exec` carries every parameter in the query string, so the head is the
  # whole request and there is never a body to read.
  defp read_head(socket, acc \\ "") do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if String.contains?(acc, "\r\n\r\n"), do: {:ok, acc}, else: read_head(socket, acc)

      {:error, _reason} ->
        :error
    end
  end

  defp headers(raw) do
    [head | _body] = String.split(raw, "\r\n\r\n", parts: 2)
    [_request_line | lines] = String.split(head, "\r\n")

    Map.new(lines, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> {String.downcase(name), String.trim(value)}
        [name] -> {String.downcase(name), ""}
      end
    end)
  end

  # --- kubeconfig ---

  defp build_kubeconfig(port, user) do
    Kubereq.Kubeconfig.new!(
      current_context: "fake",
      current_cluster: %{
        "server" => "https://127.0.0.1:#{port}",
        # No CA plumbing: the client trusts whatever the listener presents.
        "insecure-skip-tls-verify" => true
      },
      current_user: user,
      contexts: [],
      clusters: [],
      users: [],
      current_namespace: "cc-fake"
    )
  end

  # Reusing the listener's own keypair as a *client* certificate is fine —
  # nothing verifies it. The point is that `Kubereq.Step.Auth` then puts the DER
  # into `connect_options`, where an unnormalized upgrade error would inspect it
  # in full.
  defp build_user(:client_cert, tls) do
    {key_type, key_der} = tls[:key]

    %{
      "client-certificate-data" => pem64(:Certificate, tls[:cert]),
      "client-key-data" => pem64(key_type, key_der)
    }
  end

  defp build_user(user, _tls) when is_map(user), do: user

  defp pem64(type, der),
    do: Base.encode64(:public_key.pem_encode([{type, der, :not_encrypted}]))

  # OTP's own self-signed-chain generator, returning DER already shaped for
  # `:ssl`'s `:cert`/`:key` options. Nothing is written to disk: no tmp
  # directory to create, no key file to forget to delete, and no PEM round trip.
  #
  # The key parameters are not decoration: `pkix_test_data/1`'s defaults produce
  # a chain TLS 1.3 refuses to use — `no_suitable_signature_algorithm` on an
  # implicit curve, `unable_to_supply_acceptable_cert` on the default digest.
  #
  # The curve is the OID rather than `:secp256r1` because that is what the
  # contract says: `cert_opt()` is `{key, {namedCurve, oid()} | …}`. OTP happens
  # to normalize the atom form at runtime, so the atom worked — while dialyzer
  # correctly proved the call breaks the contract, which made this function
  # `no_return` and every line of `init/1` after it unreachable. Three helpers
  # were then reported as dead code that is in fact called on every start.
  #
  # `{1, 2, 840, 10045, 3, 1, 7}` is prime256v1, a.k.a. secp256r1, a.k.a. NIST
  # P-256.
  @p256 {1, 2, 840, 10_045, 3, 1, 7}

  defp tls_material do
    params = [key: {:namedCurve, @p256}, digest: :sha256]

    :public_key.pkix_test_data(%{root: params, peer: params})
    |> Keyword.take([:cert, :key])
  end
end
