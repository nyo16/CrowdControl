defmodule CrowdControl.Provider.Gce.Tunnel do
  @moduledoc """
  An SSH tunnel from this node's loopback to one sandbox VM's loopback agent
  port, with a private key that never touches disk.

  Everything here was established empirically against OTP 29's `:ssh` and
  against a real `OpenSSH 10.3p1` sshd — which is what a GCE VM runs — rather
  than from the API docs. The load-bearing results:

    * **`:loopback` is mandatory.** `tcpip_tunnel_to_server/6` with
      `ListenHost = :any` (or `{0,0,0,0}`) binds the local listener on *every*
      interface, publishing the sandbox agent to the LAN, and still returns a
      perfectly normal `{:ok, port}`. There is no error to catch, which is why
      it is a constant here and a test there.
    * **`{:ok, port}` is not evidence of reachability.** The call only does a
      local `gen_tcp:listen`; the `direct-tcpip` channel is opened lazily, per
      accepted connection. A tunnel to a closed remote port succeeds
      identically. `GET /v1/health` is the only readiness proof, which is what
      makes `c:CrowdControl.Provider.acquire/1`'s contract mandatory rather
      than stylistic.
    * **The `Timeout` argument is ignored** by the handler, so this module
      never relies on it.
    * **`false` from `is_host_key/5` does not reject a host key** when
      `silently_accept_hosts: true` — OTP overrides it. Only `{:error, _}` is
      honoured on both settings. Both are set the safe way here.
    * **`save_accepted_host` defaults to `true`**, so it is switched off
      explicitly: no code path may write a `known_hosts` file.
    * **`:user_dir` is validated to exist** even when a custom `key_cb` never
      reads it, so an empty directory has to exist somewhere.
    * **A `key_cb` failure reason never reaches the caller.** `:ssh.connect/4`
      collapses everything into `"Key exchange failed"` or `"Unable to connect
      using the available authentication methods"`. The only way out is for the
      callback to report to the calling process, which is what
      `KeyCb` does.

  ## The keypair is derived, not random

  A random per-session keypair cannot survive `c:CrowdControl.Provider.reconnect/1`:
  the key lives in RAM, `gcp_compute` has no `instances.setMetadata`, so the
  VM's `authorized_keys` is fixed at create time and a node restart would leave
  a live sandbox permanently unreachable.

  So the ed25519 seed is `sha256("cc-gce-ssh/v1" <> agent_token)`, where the
  agent token is `CrowdControl.Provider.token/1` — itself an HMAC of
  `:sandboxd_secret` over the session key. `reconnect/1` therefore
  re-derives the identical keypair from the persisted `session_key` alone, and
  the private half still never exists anywhere but memory. It is the same trade
  the agent token already makes, with the same failure mode: rotating
  `:sandboxd_secret` fails reattach closed.

  The seed is one-way from the token (sha256 of it, with a domain tag), so
  neither derived secret discloses the other, and both are per-session.

  ## Host keys: what is and is not checked

  `:host_key_fp` pins the VM's host key by SHA-256 fingerprint when the caller
  has one. Nothing supplies it for an ordinary per-session VM: a fresh GCE
  guest generates its host key on first boot, and reading it back needs
  `instances.getSerialPortOutput`, which `gcp_compute` does not wrap.

  So by default the first host key presented is accepted. Two alternatives were
  considered and rejected: `silently_accept_hosts: true` (strictly worse — it
  also disables pinning when a fingerprint *is* known), and generating the host
  key ourselves and shipping its private half in instance metadata (which would
  make it readable by every project viewer, i.e. would hand the MITM key to
  more parties than it protects against). This is a documented regression
  against `CrowdControl.Provider.Docker`, where the transport is a loopback
  socket and there is nothing to authenticate.

  ## Teardown

  `:ssh.close/1` is the only way to remove a tunnel: `:ssh.stop_listener/2`
  returns `:ok` and does nothing to a forward listener, and repeated
  `tcpip_tunnel_to_server/6` calls stack up additional listeners. `close/1` is
  idempotent, and dropping the connection closes the local port promptly — an
  in-flight request fails within milliseconds rather than hanging.
  """

  alias CrowdControl.Provider

  @ssh_user "ccsandbox"
  @default_ssh_port 22
  @default_agent_port 8080

  @connect_timeout 10_000
  @retry_interval 2_000

  # Ignored by the handler; passed because the arity-6 call is the one that
  # returns the assigned local port.
  @tunnel_timeout 5_000

  @key_domain "cc-gce-ssh/v1"
  # id-Ed25519. The record below is byte-identical to what
  # :public_key.generate_key({:namedCurve, :ed25519}) returns; building it by
  # hand is the only way to make it reproducible from a seed.
  @ed25519_oid {1, 3, 101, 112}

  @report_tag :cc_gce_host_key

  @typedoc "An `:ssh` connection reference — a local pid, never persisted."
  @type conn :: pid()

  @typedoc "An OTP `#'ECPrivateKey'{}` record holding an ed25519 keypair."
  @type keypair :: tuple()

  @doc "The Linux user the tunnel authenticates as."
  @spec ssh_user() :: String.t()
  def ssh_user, do: @ssh_user

  @doc """
  The session's ed25519 keypair, derived from `session_key`.

  In memory only, and identical on every call for a given session key and
  `:sandboxd_secret` — see the moduledoc for why that is a requirement rather
  than a shortcut.
  """
  @spec keypair(String.t()) :: keypair()
  def keypair(session_key) when is_binary(session_key) do
    seed = :crypto.hash(:sha256, @key_domain <> Provider.token(session_key))
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)

    {:ECPrivateKey, :ecPrivkeyVer1, private, {:namedCurve, @ed25519_oid}, public, :asn1_NOVALUE}
  end

  @doc """
  The `ssh-keys` metadata value that authorizes this session's key.

  `USERNAME:KEY_VALUE`, the format the guest agent's `getUserKeys` parses. The
  non-expiring form is deliberate: expiry lives in a `google-ssh {json}` key
  *comment*, a malformed `expireOn` makes the guest agent drop the key
  entirely — total silent failure — and a custom comment before the marker
  silently disables expiry anyway. Exposure is bounded by VM deletion and
  `scheduling.maxRunDuration` instead, both of which are enforced server-side.
  """
  @spec metadata_ssh_keys(String.t()) :: String.t()
  def metadata_ssh_keys(session_key) when is_binary(session_key) do
    public_key = session_key |> keypair() |> then(&:ssh_file.extract_public_key/1)

    line =
      [{public_key, [comment: ~c"crowd_control"]}]
      |> :ssh_file.encode(:openssh_key)
      |> String.trim_trailing()

    "#{@ssh_user}:#{line}"
  end

  @doc """
  Connect to `host` and forward a fresh loopback port to the VM's agent port.

  Returns `{:ok, local_port, conn}`. `conn` belongs in
  `CrowdControl.Provider.Endpoint`'s `:transport`, never in a persisted handle:
  it is a local pid, and the local port is OS-assigned and different on every
  reconnect.

  ## Options

    * `:ssh_port` — default `22`
    * `:agent_port` — the port `sandboxd` binds on the VM's loopback,
      default `8080`
    * `:deadline` — a `System.monotonic_time(:millisecond)` deadline for the
      whole retry loop; defaults to one `:connect_timeout` from now
    * `:connect_timeout` — per attempt, default `10_000`
    * `:host_key_fp` — pin the VM's host key by `"SHA256:…"` fingerprint

  Three connect failures are retried until the deadline, because all three are
  the *normal* state of a booting VM: `:econnrefused` (sshd not listening yet),
  `:timeout` (TCP accepts, no SSH banner yet), and authentication failure (the
  guest agent has not yet turned the metadata key into an `authorized_keys`
  line). Surfacing any of them immediately would fail every acquire.
  """
  @spec open(String.t(), String.t(), keyword()) ::
          {:ok, pos_integer(), conn()} | {:error, term()}
  def open(host, session_key, opts \\ []) when is_binary(host) and is_binary(session_key) do
    with :ok <- ensure_ssh!(),
         {:ok, user_dir} <- user_dir() do
      connect_timeout = opts[:connect_timeout] || @connect_timeout
      deadline = opts[:deadline] || System.monotonic_time(:millisecond) + connect_timeout

      connect_opts = connect_opts(session_key, user_dir, opts[:host_key_fp])

      case connect(
             charlist(host),
             opts[:ssh_port] || @default_ssh_port,
             connect_opts,
             connect_timeout,
             deadline
           ) do
        {:ok, conn} -> tunnel(conn, opts[:agent_port] || @default_agent_port)
        {:error, reason} -> {:error, {:gce, {:tunnel, reason}}}
      end
    end
  end

  @doc """
  Close a tunnel and every forward listener under it.

  Idempotent, and a no-op for a handle that never had one.
  """
  @spec close(conn() | nil) :: :ok
  def close(nil), do: :ok

  def close(conn) when is_pid(conn) do
    _ = safely(fn -> :ssh.close(conn) end, :ok)
    :ok
  end

  @doc """
  Whether the SSH connection is still up.

  The disambiguator for an agent HTTP failure: the transport error is
  `:socket_closed_remotely` whether the agent is not listening, forwarding was
  denied, the SSH connection dropped, or the VM is gone. Only the connection
  ref can tell those apart.
  """
  @spec alive?(conn() | nil) :: boolean()
  def alive?(nil), do: false

  def alive?(conn) when is_pid(conn) do
    # `:ssh.connection_info/2` returns the proplist DIRECTLY when alive, not
    # `{:ok, list}` — unlike `:ssh.daemon_info/1`.
    #
    # The list check is out here rather than inside the closure so this function
    # is *provably* boolean. Inside, its result flows through `safely/2`, whose
    # inferred return is the union across all its call sites — `close/1` passes
    # `:ok` and `:ssh.close/1` returns `:ok | {:error, _}` — and dialyzer then
    # reads this function's `boolean()` spec as incomplete.
    case safely(fn -> :ssh.connection_info(conn, [:peer]) end, :closed) do
      info when is_list(info) -> true
      _closed_or_error -> false
    end
  end

  # --- private ---

  defp connect_opts(session_key, user_dir, host_key_fp) do
    private = [
      priv_key: keypair(session_key),
      host_key_fp: host_key_fp,
      report_to: self()
    ]

    [
      {:user, charlist(@ssh_user)},
      {:key_cb, {__MODULE__.KeyCb, private}},
      {:auth_methods, ~c"publickey"},
      {:pref_public_key_algs, [:"ssh-ed25519"]},
      {:user_interaction, false},
      # MUST be false: with `true`, OTP accepts a host key our callback
      # rejected with `false`, silently defeating :host_key_fp.
      {:silently_accept_hosts, false},
      # Defaults to true, and would let add_host_key/4 write known_hosts.
      {:save_accepted_host, false},
      {:user_dir, user_dir}
    ]
  end

  defp connect(host, port, opts, timeout, deadline) do
    case :ssh.connect(host, port, opts, timeout) do
      {:ok, conn} ->
        _ = drain_reports(:ok)
        {:ok, conn}

      {:error, reason} ->
        # The classification is the fallback; a report from the callback is
        # more specific and wins.
        classified = drain_reports(classify(reason))

        if retryable?(classified) and
             System.monotonic_time(:millisecond) + @retry_interval < deadline do
          Process.sleep(@retry_interval)
          connect(host, port, opts, timeout, deadline)
        else
          {:error, classified}
        end
    end
  end

  defp tunnel(conn, agent_port) do
    case :ssh.tcpip_tunnel_to_server(
           conn,
           :loopback,
           0,
           ~c"127.0.0.1",
           agent_port,
           @tunnel_timeout
         ) do
      {:ok, local_port} ->
        {:ok, local_port, conn}

      {:error, reason} ->
        # A connection with no tunnel is useless and would otherwise sit there
        # holding an authenticated session open.
        close(conn)
        {:error, {:gce, {:tunnel, {:local_bind, reason}}}}
    end
  end

  defp classify(:econnrefused), do: :sshd_unreachable
  defp classify(:ehostunreach), do: :sshd_unreachable
  defp classify(:enetunreach), do: :sshd_unreachable
  defp classify(:nxdomain), do: :sshd_unreachable
  # TCP accepted but no SSH banner: the common case while sshd is starting.
  defp classify(:timeout), do: :sshd_not_ready

  defp classify(reason) when is_list(reason) do
    text = List.to_string(reason)

    cond do
      text =~ "authentication methods" -> :auth_failed
      text =~ "Key exchange failed" -> :host_key_rejected
      true -> {:ssh, text}
    end
  end

  defp classify(reason), do: {:ssh, reason}

  # Every retryable reason is a *normal* state of a VM that is still booting.
  # :auth_failed included: the guest agent turns metadata `ssh-keys` into an
  # authorized_keys line only after its first metadata poll, so publickey auth
  # genuinely fails for the first seconds of a VM's life.
  defp retryable?(reason), do: reason in [:sshd_unreachable, :sshd_not_ready, :auth_failed]

  defp drain_reports(default) do
    receive do
      {@report_tag, reason} -> drain_reports(reason)
    after
      0 -> default
    end
  end

  # :user_dir is validated to exist even though KeyCb never reads it, so one
  # empty directory has to exist. Nothing ever writes into it:
  # save_accepted_host is false and add_host_key/4 refuses, and the custom
  # key_cb resolves host keys from its own opts rather than from disk. So a
  # hostile pre-created directory yields nothing to read and nothing to poison;
  # the worst case is mkdir_p failing, which is returned as an error.
  #
  # sobelow_skip because the path has no caller input in it at all — it is
  # System.tmp_dir!() joined to a literal — and Traversal.FileModule flags any
  # File.mkdir_p/1 whose argument is a variable.
  # sobelow_skip ["Traversal.FileModule"]
  defp user_dir do
    dir = Path.join(System.tmp_dir!(), "cc-gce-ssh")

    case File.mkdir_p(dir) do
      :ok -> {:ok, charlist(dir)}
      {:error, reason} -> {:error, {:gce, {:tunnel, {:user_dir, reason}}}}
    end
  end

  defp ensure_ssh! do
    case Application.ensure_all_started(:ssh) do
      {:ok, _started} ->
        :ok

      {:error, reason} ->
        raise """
        CrowdControl.Provider.Gce could not start the OTP :ssh application: #{inspect(reason)}

        :ssh ships with Erlang/OTP but is not started by default, and a release
        only includes applications it can see. Add it to your own app:

            def application do
              [extra_applications: [:logger, :ssh]]
            end
        """
    end
  end

  # :ssh calls are gen_statem calls against a connection process that may have
  # died between the check and the call, and a teardown path must never turn
  # that race into an exit.
  #
  # A polymorphic spec so a caller reading this knows the default is returned
  # verbatim. It does not narrow anything for dialyzer — `result: term()` is
  # wider than any call site's actual type — so a function whose own spec is
  # narrower than `term()` must make that narrowing explicit itself, as
  # `alive?/1` does. Same shape as `CrowdControl.Backend.safe/2`.
  @spec safely((-> result), default) :: result | default
        when result: term(), default: term()
  defp safely(fun, default) do
    fun.()
  catch
    :exit, _reason -> default
  end

  defp charlist(value), do: String.to_charlist(value)

  defmodule KeyCb do
    @moduledoc false
    # The in-memory `key_cb`. `user_key/2` + `is_host_key/5` + `add_host_key/4`
    # is the minimum viable set: `is_host_key/4` and `add_host_key/3` are the
    # optional halves of their pairs, and `sign/3` is fully optional.
    #
    # `Options` arrives as `[{key_cb_private, KeyCbOpts} | UserOpts]`, where
    # KeyCbOpts is whatever was passed as `{key_cb, {Mod, KeyCbOpts}}`. That
    # list is the channel for the in-memory key, and the whole reason "never on
    # disk" is possible.

    @behaviour :ssh_client_key_api

    @report_tag :cc_gce_host_key

    @impl true
    def user_key(:"ssh-ed25519", opts) do
      case private(opts, :priv_key) do
        :undefined -> {:error, ~c"no in-memory ed25519 key was provided"}
        keypair -> {:ok, keypair}
      end
    end

    def user_key(algorithm, _opts), do: {:error, ~c"unsupported algorithm: #{algorithm}"}

    @impl true
    def is_host_key(key, _host, _port, _algorithm, opts) do
      case private(opts, :host_key_fp) do
        nil -> true
        :undefined -> true
        expected -> verify(key, expected, opts)
      end
    end

    defp verify(key, expected, opts) do
      fingerprint = to_string(:ssh.hostkey_fingerprint(:sha256, key))

      if fingerprint == expected do
        true
      else
        # `false` would NOT reject this key if silently_accept_hosts were true;
        # `{:error, _}` is honoured either way. The reason is also reported,
        # because :ssh.connect/4 replaces it with "Key exchange failed".
        report(opts, {:host_key_mismatch, fingerprint})
        {:error, {:host_key_mismatch, fingerprint}}
      end
    end

    @impl true
    def add_host_key(_host, _port, _key, _opts), do: {:error, :not_persisting_host_keys}

    # `:proplists.get_value/2,3` takes the key FIRST. Piping `opts` in reads
    # nicely and silently asks for the wrong thing, and :ssh swallows the
    # resulting badarg into "No host key available" / an auth failure.
    defp private(opts, key) do
      :proplists.get_value(key, :proplists.get_value(:key_cb_private, opts, []), :undefined)
    end

    defp report(opts, reason) do
      case private(opts, :report_to) do
        pid when is_pid(pid) -> send(pid, {@report_tag, reason})
        _ -> :ok
      end
    end
  end
end
