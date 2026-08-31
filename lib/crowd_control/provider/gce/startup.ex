defmodule CrowdControl.Provider.Gce.Startup do
  @moduledoc """
  Renders the `startup-script` that turns a bare Debian VM into a sandbox
  running `sandboxd`.

  Pure: `render/1` takes options and returns a string. No cloud, no network, no
  side effects — which matters because this script is the one part of
  `CrowdControl.Provider.Gce` that cannot be observed from the BEAM once it
  starts running. A rendering bug is otherwise only visible as a VM that never
  answers `GET /v1/health`, minutes later, on a substrate that bills by the
  second.

  ## No secret is ever in the script body

  The rendered text is stored in instance metadata, and instance metadata is
  readable by anything that can `compute.instances.get` the VM — a
  `roles/compute.viewer` on the project included. So the script contains no
  token. It fetches `attributes/cc-sandboxd-token` from the metadata server at
  service start and exports it into `sandboxd`'s environment only, so
  `CC_SANDBOXD_TOKEN` exists in exactly one process's environment and nowhere
  on disk.

  Anything on the VM that can reach the metadata server can read that token,
  including the sandboxed CLI. That is not an escalation — the token only
  authorizes `exec`/`stdin`/`stream` against the agent running beside it, which
  that code already drives — but it is precisely why no *other* credential may
  travel this way, and why `CrowdControl.Provider.Gce` attaches no service
  account by default.

  ## The release is verified, not trusted

  `:sandboxd_url` is fetched over the network onto a VM that then runs it as a
  service, so `:sandboxd_sha256` is **mandatory**. A missing checksum is a
  validation error rather than a skipped check: "no checksum configured" and
  "checksum verified" must never be the same code path. `set -euo pipefail`
  plus an explicit `sha256sum -c` means a mismatched artifact is never
  extracted, so the agent never answers health, so `acquire/1` destroys the VM.

  ## The expected artifact

  CI publishes `sandboxd-linux-amd64.tar.gz` / `sandboxd-linux-arm64.tar.gz`
  with a `.sha256` sidecar. The archive's top level is `sandboxd/`
  (`bin`, `erts-*`, `lib`, `releases`), so it is unpacked with `tar -C /opt`
  and lands on `/opt/sandboxd/bin/sandboxd`. Pass the sidecar's hash as
  `:sandboxd_sha256`, and pick the tarball matching the `:machine_type`'s
  architecture — an OTP release must run on the glibc and CPU it was built for.

  ## Ordering

  The caller's `:bootstrap_script` runs **before** the agent is installed, as
  root. That ordering is load-bearing: `GET /v1/health` is the provider's only
  readiness signal, and putting the bootstrap first makes a healthy agent imply
  a finished bootstrap. Reversed, a sandbox would pass health while `node` and
  the agent CLI were still installing, and the session's first `exec` would
  fail on a sandbox that looked ready.

  ## Two accounts, deliberately

  `sandboxd` runs as an unprivileged `ccagent` system user, not as root and not
  as the SSH user. The guest agent adds metadata SSH users to `google-sudoers`,
  so running the agent as the tunnel's SSH user would hand every `exec`
  passwordless root on the VM.

  ## Options

    * `:sandboxd_url` — URL of the release tarball described above (required)
    * `:sandboxd_sha256` — that archive's SHA-256, 64 hex characters (required)
    * `:bootstrap_script` — shell run as root before the agent is installed;
      omit it for an image that already carries the agent CLI
    * `:agent_port` — the port `sandboxd` binds on the VM's loopback, default
      `8080`. Must be above 1024: the agent is not root and gets no
      `CAP_NET_BIND_SERVICE`.
    * `:capture_path` — default `/var/log/cc/out.jsonl`
  """

  @token_metadata_key "cc-sandboxd-token"

  @default_agent_port 8080
  @default_capture "/var/log/cc/out.jsonl"

  @agent_user "ccagent"
  @install_dir "/opt"
  @release_dir "/opt/sandboxd"
  @workspace "/workspace"
  @runner "/usr/local/bin/cc-sandboxd-run"
  @unit "/etc/systemd/system/cc-sandboxd.service"

  @url ~r{\A https?:// [^\s'"\\]+ \z}x
  @sha256 ~r/\A[0-9a-fA-F]{64}\z/

  @doc false
  @spec render(keyword()) :: {:ok, String.t()} | {:error, term()}
  def render(opts) do
    with {:ok, url} <- fetch_url(opts),
         {:ok, sha256} <- fetch_sha256(opts),
         {:ok, port} <- fetch_agent_port(opts),
         {:ok, capture} <- fetch_capture_path(opts),
         {:ok, bootstrap} <- fetch_bootstrap(opts) do
      {:ok, script(url, sha256, port, capture, bootstrap)}
    end
  end

  @doc false
  @spec token_metadata_key() :: String.t()
  def token_metadata_key, do: @token_metadata_key

  # --- validation ---

  defp fetch_url(opts) do
    case opts[:sandboxd_url] do
      url when is_binary(url) ->
        if Regex.match?(@url, url),
          do: {:ok, url},
          else: {:error, {:gce, {:bad_sandboxd_url, url}}}

      nil ->
        {:error, {:gce, :sandboxd_url_required}}

      other ->
        {:error, {:gce, {:bad_sandboxd_url, other}}}
    end
  end

  defp fetch_sha256(opts) do
    case opts[:sandboxd_sha256] do
      hex when is_binary(hex) ->
        if Regex.match?(@sha256, hex),
          do: {:ok, String.downcase(hex)},
          else: {:error, {:gce, {:bad_sandboxd_sha256, hex}}}

      # Not defaulted, not inferred, not skippable. See the moduledoc.
      nil ->
        {:error, {:gce, :sandboxd_sha256_required}}

      other ->
        {:error, {:gce, {:bad_sandboxd_sha256, other}}}
    end
  end

  defp fetch_agent_port(opts) do
    case opts[:agent_port] || @default_agent_port do
      port when is_integer(port) and port > 1024 and port < 65_536 -> {:ok, port}
      other -> {:error, {:gce, {:bad_agent_port, other}}}
    end
  end

  defp fetch_capture_path(opts) do
    path = opts[:capture_path] || @default_capture

    if is_binary(path) and String.starts_with?(path, "/") and shell_safe?(path) and
         Path.dirname(path) != "/" do
      {:ok, path}
    else
      {:error, {:gce, {:bad_capture_path, path}}}
    end
  end

  defp fetch_bootstrap(opts) do
    case opts[:bootstrap_script] do
      nil -> {:ok, nil}
      script when is_binary(script) -> {:ok, script}
      other -> {:error, {:gce, {:bad_bootstrap_script, other}}}
    end
  end

  # Every interpolated value below is single-quoted in the script, and inside
  # single quotes `sh` interprets nothing at all — except a single quote. So
  # that one character, plus anything that could end the line, is the whole
  # gate. Rejecting rather than escaping keeps the audit trivial: there is no
  # quoting left to get wrong. `:bootstrap_script` is exempt by construction —
  # it is caller-authored shell, spliced in as shell.
  defp shell_safe?(value) do
    not String.contains?(value, ["'", "\n", "\r", "\0"])
  end

  # --- rendering ---

  defp script(url, sha256, port, capture, bootstrap) do
    """
    #!/bin/bash
    # Rendered by CrowdControl.Provider.Gce.Startup. Runs once, as root, on
    # first boot, and carries no credential: instance metadata is readable by
    # every project viewer.
    set -euo pipefail

    export DEBIAN_FRONTEND=noninteractive

    # libssl3 and libncurses6 are both mandatory, and both were established by
    # the release failing without them on a bare Debian image. The release
    # embeds ERTS (include_erts: true), but ERTS's crypto NIF still links
    # against the system OpenSSL:
    #
    #   Failed to load NIF library .../crypto: 'libcrypto.so.3: cannot open
    #   shared object file'
    #
    # ca-certificates happens to pull OpenSSL in today; that is not a contract,
    # so libssl3 is named explicitly.
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \\
      ca-certificates curl tar libssl3 libncurses6

    #{bootstrap_section(bootstrap)}
    # --- fetch and verify the agent release ---
    #
    # Verified, not trusted: a mismatch exits non-zero here, before anything is
    # extracted, and `set -e` means the agent is never installed at all.
    archive_dir="$(mktemp -d)"
    archive="$archive_dir/sandboxd.tar.gz"

    curl -fsS --retry 5 --retry-connrefused --retry-delay 2 --max-time 600 \\
      -o "$archive" '#{url}'

    if ! printf '%s  %s\\n' '#{sha256}' "$archive" | sha256sum -c - >/dev/null; then
      echo 'cc-startup: sandboxd checksum mismatch - refusing to install' >&2
      exit 1
    fi

    # The archive's top level is `sandboxd/`, so this unpacks onto
    # #{@release_dir} rather than into it.
    rm -rf '#{@release_dir}'
    tar -xzf "$archive" -C '#{@install_dir}'
    rm -rf "$archive_dir"
    test -x '#{@release_dir}/bin/sandboxd'

    # --- the account the untrusted CLI runs as ---
    #
    # Neither root nor the SSH user: the guest agent puts metadata SSH users in
    # google-sudoers, so running the agent as that user would make every exec
    # passwordless root.
    id -u '#{@agent_user}' >/dev/null 2>&1 || useradd --system --create-home \\
      --home-dir '/home/#{@agent_user}' --shell /bin/bash '#{@agent_user}'

    install -d -m 0750 -o '#{@agent_user}' -g '#{@agent_user}' '#{Path.dirname(capture)}'
    install -d -m 0750 -o '#{@agent_user}' -g '#{@agent_user}' '#{@workspace}'

    # --- the launcher: the only place the token ever exists ---
    #
    # Fetched per start, exported into this process, never written to disk.
    cat > '#{@runner}' <<'CC_RUNNER'
    #!/bin/bash
    set -euo pipefail

    CC_SANDBOXD_TOKEN="$(curl -fsS -H 'Metadata-Flavor: Google' \\
      'http://metadata.google.internal/computeMetadata/v1/instance/attributes/#{@token_metadata_key}')"
    export CC_SANDBOXD_TOKEN
    export CC_SANDBOXD_PORT='#{port}'
    # Loopback only. The agent is reachable exclusively through the caller's SSH
    # tunnel; a VM-wide bind would publish it to the whole VPC.
    export CC_SANDBOXD_BIND='127.0.0.1'
    export CC_SANDBOXD_CAPTURE='#{capture}'

    # `start` runs in the foreground under Type=exec. `stop`, `rpc`, `remote`
    # and `eval` are unusable here by design: rel/env.sh.eex sets
    # RELEASE_DISTRIBUTION=none, so the release never registers with EPMD —
    # which would be an extra listening port on a host running untrusted code,
    # and one CC_SANDBOXD_BIND does not govern. Teardown is POST /v1/shutdown
    # or SIGTERM, both of which systemd and the provider already use.
    exec '#{@release_dir}/bin/sandboxd' start
    CC_RUNNER

    chmod 0755 '#{@runner}'

    cat > '#{@unit}' <<'CC_UNIT'
    [Unit]
    Description=CrowdControl sandboxd agent
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=exec
    User=#{@agent_user}
    Group=#{@agent_user}
    WorkingDirectory=#{@workspace}
    ExecStart=#{@runner}
    Restart=on-failure
    RestartSec=2
    NoNewPrivileges=yes
    # RELEASE_TMP defaults to the release root's own tmp/, which is root-owned
    # here while the agent is not. The release only writes there when it has a
    # config/runtime.exs -- which sandboxd does not today -- and the failure if
    # it ever gains one is "could not write ... .runtime" at boot, on a VM whose
    # only symptom is that health never answers. Two lines now instead.
    RuntimeDirectory=cc-sandboxd
    Environment=RELEASE_TMP=/run/cc-sandboxd

    [Install]
    WantedBy=multi-user.target
    CC_UNIT

    systemctl daemon-reload
    systemctl enable --now cc-sandboxd.service
    """
  end

  defp bootstrap_section(nil) do
    """
    # No :bootstrap_script: the caller's image is expected to already carry the
    # agent CLI.
    """
  end

  defp bootstrap_section(script) do
    """
    # --- caller-supplied :bootstrap_script, verbatim, as root, first ---
    #
    # `set -e` is still in force, so a failing bootstrap aborts before the agent
    # is installed. That is the intended shape: health never answers, and
    # acquire/1 destroys the VM rather than handing back a half-built sandbox.
    #{script}
    # --- end :bootstrap_script ---
    """
  end
end
