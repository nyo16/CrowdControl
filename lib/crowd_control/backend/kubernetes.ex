defmodule CrowdControl.Backend.Kubernetes do
  @moduledoc """
  Runs the CLI inside a Kubernetes Pod over the API server.

  Requires the optional `:kubereq` dependency:

      {:kubereq, "~> 0.4.4"}

  Session-facing semantics are indistinguishable from `CrowdControl.Backend.Docker`:
  the same FIFO/tee I/O architecture, the same byte-exact resume, the same
  reader contract, `reattachable?/0 == true`. What differs is everything about
  *how*, and three of those differences are load-bearing enough to state up
  front.

  ## How I/O works

      provision  POST   /api/v1/namespaces/{ns}/pods
                 initContainer: mkfifo -m 600 <fifo> && mkdir -p <teedir>
                 container:     wait for <status>, then exit with it

      exec       POST   /api/v1/namespaces/{ns}/pods/{pod}/exec   (stdin)
                 sh -c 'umask 077; cat > <env>'      <- the secrets channel
                 then a second, detaching exec:
                 setsid sh -c 'echo $$ > <launcher>; . <env>; rm -f <env>;
                               exec 3<> <fifo>;
                               { <cli> <&3; echo $? > <status>.partial; }
                                 | tee <tee>;
                               mv -f <status>.partial <status>' \
                           </dev/null >/dev/null 2>&1 &

      write      POST   .../exec   sh -c 'printf %s <escaped> >> <fifo>'

      read       POST   .../exec   tail -c +<byte_offset + 1> -f <tee>
                 over a long-lived `Kubereq.PodExec` websocket

      destroy    DELETE /api/v1/namespaces/{ns}/pods/{pod}?gracePeriodSeconds=0

  Three details are load-bearing and were all established empirically, exactly as
  under Docker:

    * **The FIFO is held open read-write** (`exec 3<> <fifo>`). A plain
      `< <fifo>` redirect sees EOF the moment the first writer detaches, which
      collapses the pipeline and kills the CLI — so the second prompt of every
      session would be lost.
    * **`tail -c +N` is 1-indexed**, hence `byte_offset + 1`. Off by one here
      duplicates a byte per resume, which corrupts the JSON line stream.
    * **PID 1 relays the CLI's exit status**, and is not the CLI itself. The
      container's process cannot *be* the CLI, because the tee file has to outlive
      any individual exec and the CLI is started later by a detaching one. But it
      must still notice the CLI: `setsid` makes the CLI a grandchild, so while PID
      1 was `sleep infinity` a crashed CLI left the container `Running`, `tail -f`
      never ended, no `:eof` was ever cast, and the session waited forever while
      the Pod billed forever. The launcher writes the CLI's own status after `tee`
      drains — never before, or PID 1 could exit while bytes were still buffered —
      and PID 1 adopts it. A launcher killed before it can report is detected
      through its pid file and reported as exit 1, because that hang is the same
      bug one level up.

  ## Secrets travel the exec stdin channel, never argv and never the API object

  The Kubernetes exec API **has no `env` parameter** — `pods/exec` has no such
  field and `kubectl exec` has no `--env`. Docker's first-class `Env` array,
  which is what keeps provider keys out of the sandbox's own `ps` there, simply
  does not exist here. The two obvious replacements are both worse than the
  problem:

    * `env` in the Pod spec puts the key in the Pod object, i.e. in etcd,
      readable by anyone with `get pods` and printed by `kubectl describe`. That
      trades an in-sandbox `ps` leak for a cluster-wide one.
    * A `Secret` plus `envFrom` has the same etcd residency, plus `secrets`
      RBAC, plus a second object left behind on a crash.

  So the env arrives as a file written over the exec **stdin** channel
  (websocket channel 0) at `umask 077`, and the launch command sources *and
  unlinks* it before the CLI starts. The bytes never enter argv, never enter the
  API object, and the file is gone by the time the sandbox can read anything.
  This is the same env-file indirection `CrowdControl.Backend.Local` uses, with
  the same `CrowdControl.Backend.Shell.escape/1` oracle.

  ## Live and resume are the same code path

  `start_reader/3` is `reattach/2` at offset 0, as under Docker. One addition:
  because `tail -f` never ends while the Pod lives, a websocket close frame
  means the *channel* dropped, not the stream — so the reader **reconnects at
  `byte_offset`** instead of casting `:eof`. Resume is free by construction, so
  a transport blip costs nothing. `:eof` is cast only once the Pod is confirmed
  not `Running`, or after five consecutive fruitless reconnects.

  ## Two hardening regressions versus Docker

  Both are stated rather than silently dropped, and both are in `SECURITY.md`:

    * **No `PidsLimit` equivalent.** Docker sets a 512-PID fork-bomb ceiling
      deliberately and separately from `Memory`. There is no Pod-spec field for
      it; `podPidsLimit` is node-level kubelet configuration. A fork bomb in
      model output is unbounded unless the cluster operator sets it.
    * **No `noexec,nosuid` on the writable mounts.** Docker's `Tmpfs` takes
      mount flags; `emptyDir` mounts `rw,relatime` with no flag control, so
      `/tmp` can stage and execute a binary even under
      `readOnlyRootFilesystem: true`.

  Against that, two hardening requirements exist here that Docker has no
  analogue for, and they are **not options**:

    * `automountServiceAccountToken: false` — a default Pod is handed a
      projected API credential and a reachable API server. That is a live
      cluster credential sitting on disk inside a sandbox running untrusted
      model-driven code.
    * `enableServiceLinks: false` — otherwise every Service's host and port is
      injected into the sandbox's environment: free cluster reconnaissance.

  ## Network posture is never inferred

  Unlike Docker, where `:network_mode` defaults to `"none"` and a Pod therefore
  starts with no network at all, a Kubernetes Pod always has cluster networking.
  There is no "none". `:network` is therefore explicit:

    * `:deny_all` — this backend creates a deny-all `Ingress`+`Egress`
      NetworkPolicy selecting the Pod, before the Pod exists, and deletes it
      with the Pod.
    * `{:policy, name}` — assert a policy the caller manages. It is fetched and
      provisioning fails if it is absent, rather than trusting the claim.
    * `:unrestricted` — the Pod can reach the cluster and the internet.

  Omitting `:network` **and** setting `:proxy_url` or `:api_url` is refused with
  `{:error, {:k8s, :network_policy_required}}`, for the same reason Docker
  refuses to infer `bridge`.

  A declaration is not enforcement. NetworkPolicy objects are accepted by any
  API server, but only enforced by a CNI with a policy controller — OrbStack,
  for instance, accepts them and enforces nothing. So `:deny_all` runs a
  one-time per-cluster enforcement probe (a throwaway Pod under a deny-all
  policy attempting egress) and refuses to start on
  `{:error, {:k8s, :network_policy_not_enforced}}`. Reporting a boundary that
  does not exist is worse than refusing to start.

  ## Options

    * `:image` — Pod image (required). Needs the CLI plus `sh`, `tail`, `tee` and
      `head` on `PATH`; busybox and coreutils both suffice. `head -c` is what
      bounds the credential read — see `API.exec_stdin/5` for why stdin EOF
      cannot be used for that
    * `:namespace` — default: the kubeconfig context's namespace, else `"default"`
    * `:kubeconfig` — a `%Kubereq.Kubeconfig{}`, a pipeline module, or
      `{module, opts}`; default `Kubereq.Kubeconfig.Default`, which covers both
      a developer's `~/.kube/config` and an in-cluster ServiceAccount
    * `:network` — `:deny_all` | `{:policy, name}` | `:unrestricted`; see above
    * `:network_probe` — `false` skips the `:deny_all` enforcement probe for
      callers who already know their CNI enforces
    * `:network_probe_image` — probe image, default `"busybox:1.36"`
    * `:network_probe_url` — probe *internet* egress instead of the default,
      which is a TCP connect to the API server's ClusterIP. The default needs no
      DNS and no internet, so it does not make a security decision depend on
      external reachability; set this only if internet egress is what you need
      proven blocked
    * `:cpus` — fractional CPU limit, e.g. `1.5`
    * `:memory` — byte limit, e.g. `512 * 1024 * 1024`
    * `:tee_path` — default `/var/log/cc/out.jsonl`
    * `:fifo_path` — default `/var/run/cc.fifo`
    * `:env_path` — default `/var/run/cc.env`
    * `:volumes` — mounts, `[%{name: "ws-claim", target: "/workspace"}]`. One
      shape across every substrate; see `CrowdControl.Volume`. Here a `:name`
      is a **PersistentVolumeClaim** that must already exist and be bound, and
      a `:host_path` is a `hostPath`. Neither is created for you: provisioning
      storage needs RBAC that running sandboxes does not justify
    * `:timeout` — HTTP receive timeout, default 30s
    * `:exec_timeout` — wall-clock bound on every short exec, default 15s
    * `:provision_timeout` — wall-clock bound on reaching `Running`, default 120s
    * `:pod_poll_ms` — reader's idle Pod-liveness poll, default 60s
    * `:max_inflight_bytes` — reader backpressure watermark, default 4 MiB
    * `:proxy_url`, `:session_token` — see the egress proxy contract in
      `SECURITY.md`
    * `:runtime_class` — `runtimeClassName`, e.g. `"gvisor"` or `"kata"`. This
      is the Kubernetes-level sandboxing control and the only option here that
      changes *which kernel* the container talks to; see "Sandbox runtimes"
      below
    * `:node_selector` — map of node labels, e.g.
      `%{"sandbox.gke.io/runtime" => "gvisor"}`
    * `:tolerations` — list of raw toleration maps, needed to schedule onto the
      tainted node pools sandbox runtimes usually run on

  Hardening:

    * `:cap_drop` — default `["ALL"]`
    * `:allow_privilege_escalation` — default `false`
    * `:run_as_user` / `:run_as_group` — opt-in; sets `runAsNonRoot` too
    * `:readonly_rootfs` — default `false`. The FIFO and tee directories
      (`Path.dirname/1` of `:fifo_path` and `:tee_path`, so `/var/run` and
      `/var/log/cc` by default) are `emptyDir` volumes either way, because the
      init container has to hand the FIFO across to the sandbox. Turning this on
      makes them `medium: Memory` with a size limit, adds `/tmp`, and sets
      `readOnlyRootFilesystem` on the sandbox container.
    * `:volume_sizes` — per-mount-path size limits, applied under
      `:readonly_rootfs`; default 64Mi, 8Mi for `/var/run`

  ## RBAC

  The identity this backend runs as needs, in `:namespace`:

      pods            create, get, list, delete
      pods/exec       create
      networkpolicies create, get, delete     # only under :network :deny_all
  """

  @behaviour CrowdControl.Backend

  # :kubereq is optional, so this module must still compile without it.
  # provision/1 raises a clear message at runtime when it is genuinely missing.
  @compile {:no_warn_undefined, Kubereq}

  require Logger

  alias CrowdControl.Backend.Credentials
  alias CrowdControl.Backend.Kubernetes.API
  alias CrowdControl.Backend.Shell
  alias CrowdControl.Store

  @default_tee "/var/log/cc/out.jsonl"
  @default_fifo "/var/run/cc.fifo"
  @default_env "/var/run/cc.env"
  @container "cc"
  @init_container "cc-init"

  @default_max_inflight 4 * 1024 * 1024
  @default_provision_timeout 120_000
  @default_pod_poll_ms 60_000
  @default_probe_image "busybox:1.36"

  # Consecutive failures to *establish* a stream before the reader gives up and
  # casts :eof. A stream that opened and stayed open resets it; see
  # attach_stream/2 for why "since the last delivered byte" was the wrong
  # measure.
  @max_reconnects 5

  # No @drain_timeout: backpressure now waits on a monitor of the session rather
  # than a wall clock, because a slow consumer is not an end of stream.
  # See await_drain/1.

  # Only used when :readonly_rootfs is enabled: the FIFO and tee directories are
  # emptyDir volumes either way (the init container has to hand the FIFO across),
  # and this is what turns them into in-memory ones. `medium: Memory` keeps them
  # off the node's disk. Unlike Docker's Tmpfs there is NO way to ask for
  # noexec/nosuid here -- see the moduledoc.
  @default_volume_sizes %{
    "/tmp" => "64Mi",
    "/var/run" => "8Mi",
    "/var/log" => "64Mi",
    "/var/log/cc" => "64Mi"
  }

  # A Pod stuck in one of these will never become Running on its own, so waiting
  # out :provision_timeout tells the caller nothing it could act on.
  @fatal_waiting [
    "ImagePullBackOff",
    "ErrImagePull",
    "CreateContainerConfigError",
    "InvalidImageName"
  ]

  @rfc1123 ~r/\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/

  defstruct [
    :pod_name,
    :namespace,
    :image,
    :tee_path,
    :fifo_path,
    :env_path,
    :session_key,
    :owner,
    config: []
  ]

  @type t :: %__MODULE__{
          pod_name: String.t() | nil,
          namespace: String.t() | nil,
          image: String.t() | nil,
          tee_path: String.t(),
          fifo_path: String.t(),
          env_path: String.t(),
          session_key: String.t() | nil,
          owner: String.t() | nil,
          config: keyword()
        }

  @doc false
  @spec reattachable?() :: true
  def reattachable?, do: true

  # --- provision ---

  @impl true
  def provision(opts) do
    with :ok <- ensure_kubereq!(),
         :ok <- validate_network!(opts),
         :ok <- validate_runtime!(opts),
         {:ok, image} <- fetch_image(opts),
         session_key = opts[:session_key] || Store.new_key(),
         {:ok, pod_name} <- pod_name(session_key),
         {:ok, namespace} <- resolve_namespace(opts) do
      handle = %__MODULE__{
        pod_name: pod_name,
        namespace: namespace,
        image: image,
        tee_path: opts[:tee_path] || @default_tee,
        fifo_path: opts[:fifo_path] || @default_fifo,
        env_path: opts[:env_path] || @default_env,
        session_key: session_key,
        owner: opts[:owner] || Store.owner_id(),
        config: opts
      }

      # First, because it is the only one of these that costs nothing to check
      # and everything below it creates cluster objects.
      with :ok <- validate_volumes(handle),
           :ok <- network_preflight!(handle),
           :ok <- ensure_network_policy(handle),
           :ok <- create_pod(handle) do
        {:ok, handle}
      end
    end
  end

  defp validate_volumes(handle) do
    case CrowdControl.Volume.normalize(handle.config, mount_paths(handle) ++ [handle.env_path]) do
      {:ok, _mounts} -> :ok
      {:error, reason} -> {:error, {:k8s, reason}}
    end
  end

  defp create_pod(handle) do
    with {:ok, _pod} <- API.create_pod(handle.config, pod_manifest(handle)),
         :ok <- await_running(handle) do
      :ok
    else
      {:error, reason} ->
        # Diagnose BEFORE the rollback, because destroy/1 deletes the only thing
        # that can still be asked. Previously this path produced
        # `{:k8s, {:pod_not_ready, "CrashLoopBackOff"}}` and nothing else, and by
        # the time an operator ran `kubectl logs` the Pod was gone.
        log_provision_failure(handle, reason)

        # Roll back a created-but-not-Running Pod rather than leaking a billed
        # object, exactly as Docker rolls back a created-but-unstarted container.
        _ = destroy(handle)
        {:error, reason}
    end
  end

  # The diagnosis is logged rather than folded into the error term, deliberately.
  # `{:k8s, {:pod_not_ready, reason}}` is a value callers and tests match on;
  # widening it to carry a log blob would break that vocabulary and put a
  # multi-line container log inside a tuple that ends up in crash reports. A
  # human reads logs; a caller matches terms.
  defp log_provision_failure(handle, reason) do
    case diagnose(handle) do
      nil ->
        Logger.warning(
          "Kubernetes provision failed for #{handle.pod_name}: #{inspect(reason)} " <>
            "(no container output and no waiting message — the Pod never got far enough to say anything)"
        )

      detail ->
        Logger.warning(
          "Kubernetes provision failed for #{handle.pod_name}: #{inspect(reason)}\n#{detail}"
        )
    end
  end

  # Three sources, in the order that answers the most failures.
  #
  # Logs first, then the *previous* container's logs — which is the one that
  # matters for a CrashLoopBackOff, where the current container has produced
  # nothing precisely because the interesting run already ended. Then the
  # waiting message, which is the only source that says anything at all for an
  # ImagePullBackOff or an invalid image reference: no container ever started,
  # so there are no logs to read.
  defp diagnose(%__MODULE__{} = handle) do
    Enum.find_value(
      [
        fn -> logs_detail(handle, []) end,
        fn -> logs_detail(handle, previous: true) end,
        fn -> waiting_detail(handle) end,
        fn -> events_detail(handle) end
      ],
      fn source -> source.() end
    )
  end

  # Last, because logs and a waiting message are more specific when they exist.
  # But a Pod the node refused to start has neither: `FailedCreatePodSandBox`
  # lives only here. Without this, naming a `:runtime_class` the nodes do not
  # support costs `:provision_timeout` and the operator is told the Pod "never
  # got far enough to say anything" while the cluster was saying exactly why.
  defp events_detail(handle) do
    {:ok, events} = API.pod_events(handle.config, handle.pod_name)

    events
    |> Enum.filter(&(&1["type"] == "Warning"))
    |> Enum.take(-3)
    |> Enum.map(fn event ->
      "#{event["reason"]}: #{String.slice(to_string(event["message"]), 0, 300)}"
    end)
    |> case do
      [] -> nil
      lines -> "pod events:\n" <> Enum.join(lines, "\n")
    end
  end

  defp logs_detail(handle, opts) do
    label = if opts[:previous], do: "previous container logs", else: "container logs"

    case API.logs(handle.config, handle.pod_name, Keyword.put(opts, :container, @container)) do
      {:ok, ""} -> nil
      {:ok, text} -> "#{label}:\n#{text}"
      {:error, _reason} -> nil
    end
  end

  defp waiting_detail(handle) do
    with {:ok, pod} <- API.get_pod(handle.config, handle.pod_name),
         message when is_binary(message) and message != "" <- waiting_message(pod) do
      "container is waiting: #{message}"
    else
      _ -> nil
    end
  end

  # Kubereq.wait_until/5's :timeout is a Req receive_timeout on the underlying
  # watch, NOT a deadline -- and its event loop treats a callback's
  # `{:error, _}` as truthy, i.e. as success. So the callback only reports
  # "settled", and the Pod is re-read afterwards to say what it settled into.
  # The outer Task is the actual wall clock.
  defp await_running(handle) do
    timeout = handle.config[:provision_timeout] || @default_provision_timeout

    task =
      Task.async(fn -> API.wait_until(handle.config, handle.pod_name, &settled?/1, timeout) end)

    case Task.yield(task, timeout + 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, _} -> classify_phase(API.get_pod(handle.config, handle.pod_name))
      _ -> {:error, {:k8s, :provision_timeout}}
    end
  end

  defp settled?(:deleted), do: true

  defp settled?(pod) do
    phase(pod) in ["Running", "Succeeded", "Failed"] or waiting_reason(pod) in @fatal_waiting
  end

  defp classify_phase({:ok, pod}) do
    case {phase(pod), waiting_reason(pod)} do
      {"Running", _} -> :ok
      {_, reason} when reason in @fatal_waiting -> {:error, {:k8s, {:pod_not_ready, reason}}}
      {"Pending", _} -> {:error, {:k8s, :provision_timeout}}
      {other, _} -> {:error, {:k8s, {:pod_not_ready, other}}}
    end
  end

  defp classify_phase({:error, reason}), do: {:error, reason}

  # --- manifest ---

  @doc false
  # Exported so the entire hardening surface is assertable with no cluster.
  # This is the most important test seam in the backend: every row of the
  # Docker-parity table, plus the two k8s-only requirements, is a pure property
  # of this map. See kubernetes_unit_test.exs.
  @spec pod_manifest(t()) :: map()
  def pod_manifest(%__MODULE__{} = handle) do
    config = handle.config

    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => handle.pod_name,
        "namespace" => handle.namespace,
        "labels" => %{
          "crowd_control.session" => handle.session_key,
          "crowd_control.owner_hash" => owner_label(handle.owner),
          "crowd_control.created_at" => to_string(System.system_time(:millisecond))
        },
        # Annotation VALUES are unconstrained, so the raw owner lives here and
        # Reaper.owned_by?/3 keeps comparing exact strings. The KEY has no "/"
        # for the same reason the label keys do not: a key with a "/" has its
        # prefix must be a lowercase DNS subdomain and "_" is illegal in one.
        #
        # The three paths are here because a rebuilt handle otherwise loses them.
        # `list_live/1` reconstructs handles from the Pod, and it used to take the
        # paths from the *caller's* opts — so a session provisioned with a custom
        # `:tee_path` resumed against the default path after a reattach, reading a
        # file that does not exist, with a byte offset that referred to another
        # file entirely. The paths are provisioning facts about this sandbox, so
        # they belong on the object rather than in whichever process asks about it.
        "annotations" => %{
          "crowd_control.owner" => to_string(handle.owner),
          "crowd_control.tee_path" => handle.tee_path,
          "crowd_control.fifo_path" => handle.fifo_path,
          "crowd_control.env_path" => handle.env_path
        }
      },
      "spec" =>
        %{
          # Non-negotiable. A restarted container truncates the tee file and
          # invalidates every persisted byte_offset. Making restart impossible
          # is cheaper and safer than trying to detect it.
          "restartPolicy" => "Never",

          # Not options, and the reason they are not is in the moduledoc: a
          # projected SA token hands untrusted model-driven code a live cluster
          # credential, and service links map the cluster into its env.
          "automountServiceAccountToken" => false,
          "enableServiceLinks" => false,
          "initContainers" => [init_container_spec(handle)],
          "containers" => [container_spec(handle)],
          "volumes" => volumes(handle)
        }
        |> put_pod_security_context(config)
        |> put_scheduling(config)
    }
  end

  # The FIFO is created here, in a container that does nothing else, and NOT in
  # the sandbox.
  #
  # `mkfifo` issues `mknod(2)`, which the container runtime's seccomp profile
  # gates on CAP_MKNOD. Verified on containerd/OrbStack: `capabilities.drop:
  # ["ALL"]` alone still lets it through, and `allowPrivilegeEscalation: false`
  # alone does too, but **together** they take CAP_MKNOD out of the effective
  # set and `mkfifo` fails with ENOENT -- an error message that points at the
  # directory rather than the capability, which is exactly how this costs an
  # afternoon.
  #
  # Handing the sandbox `cap_add: ["MKNOD"]` would fix it in one line and is
  # what Docker's own default capability set does. It is still the wrong trade
  # here: the sandbox runs untrusted model-driven code for hours, and the
  # capability is needed for a single syscall at startup. An init container
  # holds it for milliseconds, exits, and leaves the FIFO on a shared volume.
  defp init_container_spec(handle) do
    %{
      "name" => @init_container,
      "image" => handle.image,
      "command" => ["/bin/sh", "-c", init_script(handle)],
      "securityContext" => %{
        "allowPrivilegeEscalation" => false,
        "capabilities" => %{"drop" => ["ALL"], "add" => ["MKNOD"]}
      },
      "volumeMounts" => volume_mounts(handle)
    }
  end

  defp container_spec(handle) do
    config = handle.config

    %{
      "name" => @container,
      "image" => handle.image,
      # PID 1 holds the Pod open until the CLI is done, then exits with the CLI's
      # status. It is deliberately not the CLI itself: the tee file has to
      # outlive any individual exec, and the CLI is started later by a detaching
      # exec that reparents to this process.
      #
      # It used to be `sleep infinity`, which made a dead CLI invisible. The CLI
      # is a grandchild after `setsid`, so when it died the container stayed
      # Running, `tail -f` never ended, no `:eof` was ever cast, and the session
      # waited forever while the Pod kept billing. Waiting on the status file
      # turns that into a terminal Pod phase, which every existing mechanism —
      # the reader's liveness check, `await_exit/2`, the reaper — already
      # understands.
      "command" => ["/bin/sh", "-c", supervise_script(handle)],
      "securityContext" =>
        %{
          # Hardening defaults, on by default for the same reason Docker's are:
          # the code running in here is model-driven and untrusted, and neither
          # breaks an ordinary CLI. Note there is no PidsLimit equivalent to set
          # alongside them -- see the moduledoc.
          "allowPrivilegeEscalation" => Keyword.get(config, :allow_privilege_escalation, false),
          "capabilities" => %{"drop" => config[:cap_drop] || ["ALL"]}
        }
        |> maybe_put("readOnlyRootFilesystem", !!config[:readonly_rootfs] || nil)
        |> put_run_as(config),
      "volumeMounts" => volume_mounts(handle)
    }
    |> maybe_put("resources", resources(config))
  end

  defp init_script(handle) do
    "mkfifo -m 600 #{Shell.escape(handle.fifo_path)} && " <>
      "mkdir -p #{Shell.escape(Path.dirname(handle.tee_path))}"
  end

  # PID 1: block until the launcher reports the CLI's status, then adopt it.
  #
  # A 1s poll rather than a blocking read on a second FIFO, because the FIFO
  # would have to be created by the init container and the poll costs nothing on
  # a path that is idle by definition. Container exit is not the latency-
  # sensitive event: the reader learns the CLI is gone the moment `tail -f` dies
  # with the container, not from the Pod phase.
  #
  # The second clause is what makes this robust rather than merely usual. The
  # status file is written by the launcher, so anything that kills the launcher
  # *before* it reports — an OOM kill of the whole process group, a `kill -9` on
  # the pipeline, a node under memory pressure — leaves a status that will never
  # arrive. Waiting on it forever would reintroduce exactly the hang this fix
  # exists to remove, one level up. So PID 1 also watches the launcher itself and
  # treats its disappearance as an abnormal end.
  #
  # Order matters: status is checked first, and the launcher writes the status
  # before exiting, so a normal end is never misread as a vanished launcher.
  #
  # `/proc/<pid>` rather than `kill -0`: it needs no signal permission and no
  # opinion about which builtins this image's `sh` shipped with.
  #
  # The status is validated before `exit` because a non-numeric argument makes
  # `sh` fail in a way that reports the wrong thing — an unreadable status means
  # "something went wrong", i.e. 1.
  defp supervise_script(handle) do
    status = Shell.escape(status_path(handle))
    pid = Shell.escape(launcher_pid_path(handle))

    "while [ ! -e #{status} ]; do " <>
      "if [ -e #{pid} ] && [ ! -d \"/proc/$(cat #{pid} 2>/dev/null)\" ]; then " <>
      "echo 1 > #{status}; break; fi; " <>
      "sleep 1; done; " <>
      "code=$(cat #{status} 2>/dev/null); " <>
      "case \"$code\" in ''|*[!0-9]*) code=1;; esac; " <>
      "exit \"$code\""
  end

  # Both live beside the FIFO, so they are inside a directory that is already an
  # emptyDir mount and already writable under :readonly_rootfs. Deriving them
  # rather than adding options keeps the handle's path set unchanged, which
  # matters because those paths are what a persisted offset refers to.
  defp status_path(handle), do: Path.join(Path.dirname(handle.fifo_path), "cc.status")
  defp launcher_pid_path(handle), do: Path.join(Path.dirname(handle.fifo_path), "cc.launcher")

  defp resources(config) do
    limits =
      %{}
      |> maybe_put("memory", config[:memory] && to_string(config[:memory]))
      |> maybe_put("cpu", config[:cpus] && "#{trunc(config[:cpus] * 1000)}m")

    if map_size(limits) == 0, do: nil, else: %{"limits" => limits}
  end

  # The FIFO and tee directories are volumes unconditionally, because the init
  # container has to hand the FIFO across to the sandbox and a container's own
  # writable layer is not shared. That also makes `:readonly_rootfs` a pure
  # toggle: the two paths the design depends on are already writable, so the
  # only thing left to decide is whether everything *else* is.
  defp mount_paths(handle) do
    [Path.dirname(handle.fifo_path), Path.dirname(handle.tee_path)]
    |> then(&if handle.config[:readonly_rootfs], do: &1 ++ ["/tmp"], else: &1)
    |> Enum.uniq()
  end

  defp volume_mounts(handle) do
    transport =
      for path <- mount_paths(handle), do: %{"name" => volume_name(path), "mountPath" => path}

    user =
      for {mount, i} <- Enum.with_index(user_volumes(handle)) do
        %{
          "name" => user_volume_name(i),
          "mountPath" => mount.target,
          "readOnly" => mount.read_only
        }
      end

    transport ++ user
  end

  # Disk-backed and unbounded by default, so the tee file is no more capped than
  # it would be on the container filesystem -- `:max_stream_bytes` is the cap
  # that exists on purpose. Under `:readonly_rootfs` they become in-memory, and
  # then a size limit is mandatory: an unbounded `medium: Memory` emptyDir is
  # charged against the node and will evict the Pod rather than fail the write.
  defp volumes(handle) do
    sizes = handle.config[:volume_sizes] || @default_volume_sizes

    transport =
      for path <- mount_paths(handle) do
        body =
          if handle.config[:readonly_rootfs] do
            %{"medium" => "Memory", "sizeLimit" => sizes[path] || "64Mi"}
          else
            %{}
          end

        %{"name" => volume_name(path), "emptyDir" => body}
      end

    transport ++ user_volume_specs(handle)
  end

  # `:name` is a PersistentVolumeClaim and `:host_path` is a hostPath, which are
  # the two things a Kubernetes Pod can mount without this library provisioning
  # storage on the caller's behalf. The claim must already exist and be bound:
  # creating one needs `persistentvolumeclaims` RBAC and leaves an object behind
  # that outlives the sandbox, which is a lifecycle this backend does not own.
  defp user_volume_specs(handle) do
    for {mount, i} <- Enum.with_index(user_volumes(handle)) do
      body =
        case mount.kind do
          :volume -> %{"persistentVolumeClaim" => %{"claimName" => mount.source}}
          :host_path -> %{"hostPath" => %{"path" => mount.source}}
        end

      Map.put(body, "name", user_volume_name(i))
    end
  end

  defp user_volumes(handle) do
    CrowdControl.Volume.normalize!(handle.config, mount_paths(handle) ++ [handle.env_path])
  end

  # Indexed rather than derived from the source: a PVC name may be up to 253
  # characters and a volume name must be a 63-character RFC 1123 label, so
  # deriving one would need truncation, and truncation collides. The mountPath
  # in the same manifest is what identifies it to a reader.
  defp user_volume_name(index), do: "cc-vol-#{index}"

  defp volume_name("/" <> rest), do: "cc-" <> String.replace(rest, "/", "-")

  defp put_run_as(security_context, config) do
    case {config[:run_as_user], config[:run_as_group]} do
      {nil, nil} ->
        security_context

      {user, group} ->
        security_context
        |> maybe_put("runAsUser", user)
        |> maybe_put("runAsGroup", group)
        |> Map.put("runAsNonRoot", user != 0)
    end
  end

  defp put_pod_security_context(spec, config) do
    if config[:run_as_user] do
      # Also at Pod level so the emptyDir volumes are group-writable by the
      # non-root user; a container-level runAsUser alone leaves them root-owned.
      Map.put(spec, "securityContext", %{
        "fsGroup" => config[:run_as_group] || config[:run_as_user]
      })
    else
      spec
    end
  end

  # --- sandbox runtime and placement ---

  # `runtimeClassName` selects a container runtime handler -- gVisor's `runsc`,
  # Kata Containers -- in place of the node's default `runc`. It is the one
  # option in this backend that changes the kernel boundary rather than what a
  # container may ask of the host kernel it already shares: capability drops,
  # `allowPrivilegeEscalation: false` and a missing service-account token all
  # narrow requests to a *shared* kernel, and a container escape defeats them
  # together. A sandbox runtime answers those syscalls somewhere else.
  #
  # Never defaulted. The RuntimeClass admission controller rejects a Pod naming
  # a RuntimeClass that does not exist, so guessing `"gvisor"` would convert
  # every working cluster without it into a provisioning failure.
  #
  # `:node_selector` and `:tolerations` ride along because a RuntimeClass alone
  # usually is not enough: sandbox node pools are tainted (GKE Sandbox uses
  # `sandbox.gke.io/runtime=gvisor:NoSchedule`), and a Pod that cannot tolerate
  # the taint stays Pending until `:provision_timeout` -- a slow, opaque failure
  # for something a caller can state in one line.
  defp put_scheduling(spec, config) do
    spec
    |> maybe_put("runtimeClassName", config[:runtime_class])
    |> maybe_put("nodeSelector", config[:node_selector])
    |> maybe_put("tolerations", config[:tolerations])
  end

  # --- naming and ownership ---

  @doc false
  # `Store.new_key/0` is 32 lowercase hex chars, so "cc-" <> key is 35 and
  # always a legal RFC 1123 label. Deterministic beats `generateName:`: a double
  # provision then fails with a detectable 409 Conflict instead of silently
  # leaving two live, billed Pods. Callers that supply their own :session_key
  # are validated rather than trusted.
  @spec pod_name(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def pod_name(session_key) when is_binary(session_key) do
    name = "cc-" <> session_key

    if byte_size(name) <= 63 and Regex.match?(@rfc1123, name) do
      {:ok, name}
    else
      {:error, {:k8s, {:invalid_name, session_key}}}
    end
  end

  def pod_name(session_key), do: {:error, {:k8s, {:invalid_name, session_key}}}

  @doc false
  # `Store.owner_id/0` defaults to `to_string(node())` = "nonode@nohost", which
  # the API server rejects as a label value ('@' is illegal). Sanitizing would
  # be lossy, and two owners collapsing to one label would let one node's reaper
  # destroy another's Pods -- so the label is a hash used purely as a selector,
  # and the raw owner round-trips through an annotation, where values are
  # unconstrained. Reaper.owned_by?/3's local re-check still compares exact
  # strings; both gates stay honest.
  @spec owner_label(String.t() | nil) :: String.t()
  def owner_label(owner) do
    :sha256
    |> :crypto.hash(to_string(owner))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # --- exec ---

  # `tee` opens the tee file `O_TRUNC`, so a second `exec/4` silently truncates
  # it — after which `tail -c +N` restarts from a new byte 0 and *every*
  # persisted cursor points at the wrong place. Nothing prevented that, and the
  # damage is invisible: no error, just a session replaying or skipping output.
  # `Backend.Sandboxd` already answers 409 for this, so refusing here makes the
  # two backends agree.
  #
  # The guard rides on the env-file write rather than costing its own round trip,
  # and it must come *before* that write for a second reason: a refused exec must
  # not re-plant the credential file, because only the launcher unlinks it and a
  # refused launch would leave the secret sitting in the sandbox.
  @impl true
  def exec(%__MODULE__{pod_name: name} = handle, executable, args, env) when is_binary(name) do
    with :ok <- write_env_file(handle, env) do
      case API.exec_once(
             handle.config,
             name,
             ["/bin/sh", "-c", launch_command(handle, executable, args)],
             container: @container
           ) do
        {:ok, _output} -> {:ok, handle}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def exec(%__MODULE__{}, _executable, _args, _env), do: {:error, :not_provisioned}

  # Two facts here are load-bearing:
  #
  #   * `exec 3<> fifo` holds a read-write fd open for the life of the pipeline,
  #     so no writer detaching is ever observable as EOF by the CLI. The plain
  #     `< fifo` form dies on the first prompt and takes the CLI with it.
  #   * The env file is sourced AND unlinked before the CLI starts, so the
  #     secret cannot be read back out of the sandbox afterwards. It never
  #     entered argv either -- it arrived over the exec stdin channel.
  #
  # `setsid ... </dev/null >/dev/null 2>&1 &` reparents the pipeline to PID 1 so
  # it outlives this exec session, which is what makes the exec "detached" in
  # the absence of Docker's `Detach: true`.
  defp launch_command(handle, executable, args) do
    argv = Enum.map_join([executable | args], " ", &Shell.escape/1)
    status = Shell.escape(status_path(handle))
    staging = Shell.escape(status_path(handle) <> ".partial")
    pid = Shell.escape(launcher_pid_path(handle))

    # Four things happen in this order, and the order is the whole point.
    #
    # `echo $$ > pid` first, and before the CLI exists, so PID 1 can tell "the
    # launcher has not started yet" from "the launcher is gone". `$$` is this
    # shell, which is the process that survives the pipeline and runs the `mv`;
    # if it dies, no status will ever arrive and PID 1 needs to know that.
    #
    # `{ CLI; echo $? > staging; } | tee` captures the CLI's own status, not the
    # pipeline's. `$?` after a bare pipeline is `tee`'s status, which is 0 even
    # when the CLI died — POSIX sh has no PIPESTATUS to reach for.
    #
    # The `mv` runs only once the pipeline has finished, which means `tee` has
    # flushed. Writing the final path directly would let PID 1 see the status,
    # exit, and take the container down while `tee` still had buffered bytes —
    # silently truncating the tail of the session's output. `mv` is atomic within
    # a filesystem, so PID 1 never observes a partial file either.
    pipeline =
      "echo $$ > #{pid}; " <>
        ". #{Shell.escape(handle.env_path)}; rm -f #{Shell.escape(handle.env_path)}; " <>
        "exec 3<> #{Shell.escape(handle.fifo_path)}; " <>
        "{ #{argv} <&3; echo $? > #{staging}; } | tee #{Shell.escape(handle.tee_path)}; " <>
        "mv -f #{staging} #{status}"

    "setsid sh -c #{Shell.escape(pipeline)} </dev/null >/dev/null 2>&1 &"
  end

  # The C1 secret channel. Rendered with the same escaper and the same shape as
  # Backend.Local's env file -- one implementation, not two -- and shipped over
  # the exec websocket's stdin channel so the bytes never touch argv or the Pod
  # object. `umask 077` means the file is 0600 from the instant it exists.
  defp write_env_file(handle, env) do
    payload =
      env
      |> Credentials.apply_credentials(handle.config)
      |> Enum.map_join("\n", fn {k, v} -> "export #{k}=#{Shell.escape(v)}" end)
      |> Kernel.<>("\n")

    handle.config
    |> API.exec_stdin(
      handle.pod_name,
      ["/bin/sh", "-c", env_write_command(handle, byte_size(payload))],
      payload,
      container: @container
    )
    |> case do
      {:error, {:k8s, {:exit_status, 99}}} -> {:error, {:k8s, :already_started}}
      other -> other
    end
  end

  @doc false
  # Doc-false public because two things in this one string are load-bearing and
  # neither is visible from the outside; both are asserted in
  # kubernetes_unit_test.exs.
  #
  # `head -c N`, not `cat`. `cat` ends only on stdin EOF, and the only way to
  # signal EOF is to close the websocket — which makes the API server tear the
  # exec down *before* it writes the channel-3 status, so a write that failed
  # reported success and the CLI started with no credentials. Measured; see
  # `API.exec_stdin/5`. Reading exactly the payload makes the command
  # self-terminating, so the status arrives on its own.
  #
  # The already-started guard comes FIRST, before anything is written. A refused
  # second `exec/4` must not re-plant the credential file, because only the
  # launcher unlinks it — a refused launch would leave the secret on disk.
  # 99 is out of the way of anything `head` or `sh` produces by itself, so the
  # code is unambiguous evidence of the guard rather than of a failed write.
  def env_write_command(handle, byte_count) do
    "if [ -e #{Shell.escape(launcher_pid_path(handle))} ] || " <>
      "[ -e #{Shell.escape(status_path(handle))} ]; then exit 99; fi; " <>
      "umask 077; head -c #{byte_count} > #{Shell.escape(handle.env_path)}"
  end

  # --- write ---

  @impl true
  def write(%__MODULE__{pod_name: name} = handle, data) when is_binary(name) do
    payload = IO.iodata_to_binary(data)

    # The prompt is attacker-influenced input crossing an `sh -c` boundary.
    # Shell.escape/1 is the same escaper Backend.Local uses for env values and
    # the one security_test.exs is the oracle for -- deliberately not a second
    # implementation.
    command = "printf %s #{Shell.escape(payload)} >> #{Shell.escape(handle.fifo_path)}"

    case API.exec_once(handle.config, name, ["/bin/sh", "-c", command], container: @container) do
      {:ok, _output} -> :ok
      # A timeout here is not a failure, it is an *unknown*. `bounded/2` kills the
      # exec task brutally and the Mint socket dies with it, but the API server
      # may already have run the `printf` — so the prompt may or may not be in the
      # FIFO. Reported as a generic timeout, the obvious response is to retry,
      # which delivers the prompt twice. Naming it lets a caller decide.
      {:error, {:k8s, :exec_timeout}} -> {:error, {:k8s, :write_indeterminate}}
      {:error, reason} -> {:error, reason}
    end
  end

  def write(%__MODULE__{}, _data), do: {:error, :not_provisioned}

  # --- read / reattach ---

  @impl true
  def start_reader(handle, session_pid, cursor), do: do_read(handle, session_pid, cursor)

  @impl true
  def reattach(%__MODULE__{pod_name: name} = handle, _cursor) when is_binary(name) do
    # Confirm the Pod is still there AND still running before the caller commits
    # to it; the reader is started separately via start_reader/3. A Pod object
    # that exists but has Succeeded or Failed cannot be exec'd into, so
    # "it resolves" is not the same question as "it is usable".
    case API.get_pod(handle.config, name) do
      {:ok, pod} ->
        case phase(pod) do
          "Running" -> {:ok, handle}
          other -> {:error, {:k8s, {:not_running, other}}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reattach(%__MODULE__{}, _cursor), do: {:error, :not_provisioned}

  defp do_read(%__MODULE__{pod_name: name} = handle, session_pid, cursor) when is_binary(name) do
    offset = Map.get(cursor, :byte_offset, 0)

    # The reader is spawn_linked per the Backend reader contract: if it dies,
    # the session must die with it rather than go silently deaf. `parent` is
    # captured HERE, in the caller, because the reader has to tell that link
    # apart from the one Kubereq.PodExec makes -- see reader_loop/1.
    parent = self()

    reader =
      spawn_link(fn ->
        # Kubereq.PodExec links to whoever called start_link/1 and stops with
        # the transport error as its reason. Without this the first websocket
        # blip kills the reader and, through the link above, the session --
        # exactly the hazard the reader contract exists to prevent.
        Process.flag(:trap_exit, true)

        reader_loop(%{
          handle: handle,
          session: session_pid,
          parent: parent,
          offset: offset,
          inflight: 0,
          podexec: nil,
          reconnects: 0,
          max_inflight: handle.config[:max_inflight_bytes] || @default_max_inflight,
          poll_ms: handle.config[:pod_poll_ms] || @default_pod_poll_ms,
          # When the current exec channel was opened; see attach_stream/2.
          opened_at: nil,
          # The last thing the container said on stderr or the exec error
          # channel. Kept so a give-up reason can name the actual cause instead
          # of an opaque transport error — see reconnect_or_eof/2.
          last_stderr: nil,
          # Channel 3's `Status`, kept separately: it arrives after stderr and
          # would otherwise overwrite it. See explain/2.
          last_exec_error: nil,
          # The last liveness answer and when it was taken; see
          # memoized_liveness/1 for why a reconnect burst does not re-ask.
          liveness: nil,
          liveness_at: nil
        })
      end)

    {:ok, reader}
  end

  defp do_read(%__MODULE__{}, _session_pid, _cursor), do: {:error, :not_provisioned}

  # Backpressure, the honest version -- the same trade as the Docker backend.
  #
  # A PodExec socket gives no flow control: frames pile into the reader's
  # mailbox whether or not Session keeps up. There is no pause primitive, but
  # the read is *resumable by construction* (`tail -c +<offset>` over the tee
  # file), so "pause" is implemented as closing the exec and "resume" as opening
  # a fresh one from the offset already delivered. No bytes are lost or
  # duplicated because the offset is exact. Tearing down the read channel never
  # touches the CLI: the reader exec is a different process from the CLI exec.
  defp reader_loop(state) do
    case open_stream(state) do
      {:ok, state} -> consume(state)
      {:error, reason} -> reconnect_or_eof(state, reason)
    end
  end

  defp open_stream(state) do
    cmd = ["tail", "-c", "+#{state.offset + 1}", "-f", state.handle.tee_path]

    # stderr: true is not cosmetic. `exec_params/2` defaults it to FALSE, so
    # without it channel 2 is never opened, the `{:stderr, data}` clause in
    # consume/1 is unreachable, and the one thing that explains a failing read
    # never arrives. Measured against a live cluster: with stderr off, a missing
    # tee file produces only `:connected` and an opaque
    # "command terminated with non-zero exit code"; with it on, the same failure
    # also delivers `tail: can't open '/var/log/cc/out.jsonl': No such file or
    # directory`. The bytes still never reach the session's stdout — consume/1
    # keeps them out — they reach the *failure reason*.
    case API.open_exec(state.handle.config, state.handle.pod_name, cmd, self(),
           container: @container,
           stderr: true
         ) do
      {:ok, podexec} -> {:ok, attach_stream(state, podexec)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Bind a reader state to a NEW exec channel.
  #
  # There is no demux state to drop here -- kubereq owns channel framing -- so
  # the invariant this seam defends is the complement of the Docker one:
  # `offset` is a position in the tee *file* and MUST survive the swap, while
  # `podexec` must be replaced wholesale.
  #
  # `opened_at` is stamped here because `reconnects` counts **consecutive
  # failures to establish a stream**, not reconnects since the last delivered
  # byte. The latter is what it used to count, and it made idle sessions
  # guaranteed to die: the reader's own comment concedes an idle session emits
  # nothing for hours, while a CRI streaming server closes an idle exec stream
  # every 4h and an ALB may do it every 60s. Any five such closes with no output
  # in between — however far apart — exhausted the budget and ended a healthy
  # session. A stream that opened and *stayed* open is progress, so
  # `reader_loop/1` clears the count on the next successful open.
  #
  # Exposed (doc-false) so both halves are testable without a cluster and a
  # precisely-timed socket failure. See kubernetes_unit_test.exs.
  def attach_stream(state, podexec) do
    %{state | podexec: podexec, opened_at: System.monotonic_time(:millisecond)}
  end

  # A stream that lived at least this long counts as having worked, so the next
  # failure starts a fresh budget. Short enough that genuine flapping (open,
  # immediate close, repeat) never resets and stays bounded by @max_reconnects.
  @stream_progress_ms 30_000

  defp note_progress(%{opened_at: nil} = state), do: state

  defp note_progress(%{opened_at: opened_at} = state) do
    if System.monotonic_time(:millisecond) - opened_at >= @stream_progress_ms do
      %{state | reconnects: 0}
    else
      state
    end
  end

  defp consume(%{parent: parent, podexec: podexec} = state) do
    receive do
      {:cc_ack, bytes} ->
        state |> ack(bytes) |> consume()

      # A zero-byte stdout frame would advance nothing but would make "the
      # reader produced output" true before any output exists, so it is dropped.
      # Note this apiserver does not actually send one — measured on
      # v1.35.6+orb1, across stdin true/false and silent and immediate commands
      # — so this clause is cheap insurance rather than a load-bearing filter,
      # and no test should claim to depend on it.
      {:stdout, ""} ->
        consume(state)

      {:stdout, data} ->
        state |> deliver(data) |> after_deliver()

      # stderr and the exec error channel never mix into the session's stdout —
      # that part is the same trade as Docker's `AttachStderr: false`. What
      # changed is that the last line is now *kept*: it is the only thing that
      # explains a failing read, and at :debug it was invisible in exactly the
      # situation where someone is trying to find out why a sandbox went quiet.
      {:stderr, data} ->
        state |> remember_stderr(data) |> consume()

      # Channel 3, the exec status. Kept apart from stderr because it always
      # arrives last and would otherwise overwrite the line that explains the
      # failure — see explain/2.
      {:error, data} ->
        state |> remember_exec_error(data) |> consume()

      :connected ->
        consume(state)

      {:close, code, reason} ->
        reconnect_or_eof(%{state | podexec: nil}, {:close, code, reason})

      {:EXIT, ^parent, reason} ->
        # The session went away. Dying with it is the other half of the reader
        # contract -- a reader that outlives its session is a leak.
        exit(reason)

      # The exec channel died. It arrives as a message rather than an exit signal
      # because `API.open_exec/5` keeps the link inside its own owner process —
      # a linked channel killed any caller that did not trap, which `guard`
      # cannot prevent, and this reader was the only caller in the tree that got
      # that right.
      {:exec_down, ^podexec, reason} ->
        reconnect_or_eof(%{state | podexec: nil}, reason)

      # A stale notice from an exec channel we already replaced. Reacting to it
      # would tear down a perfectly good connection.
      {:exec_down, _pid, _reason} ->
        consume(state)

      {:EXIT, _pid, _reason} ->
        consume(state)

      other ->
        Logger.debug("Kubernetes reader ignoring unrecognized message: #{inspect(other)}")
        consume(state)
    after
      # No data-idle timeout: an idle session legitimately emits nothing for
      # hours, so treating silence as EOF would false-positive constantly. What
      # silence DOES justify is asking the API server whether the Pod is still
      # there, so an evicted or drained Pod surfaces as :eof rather than as an
      # indefinite hang.
      state.poll_ms -> poll_pod(state)
    end
  end

  defp poll_pod(state) do
    if alive?(state.handle) do
      consume(state)
    else
      Logger.debug("Kubernetes reader: pod #{state.handle.pod_name} is no longer running")
      GenServer.cast(state.session, :eof)
    end
  end

  defp after_deliver(state) do
    if state.inflight >= state.max_inflight, do: pause(state), else: consume(state)
  end

  defp deliver(state, data) do
    GenServer.cast(state.session, {:stdout_data, data})
    size = byte_size(data)

    %{
      state
      | # The offset advances only by bytes actually handed to the session, so a
        # resume never re-reads what was already delivered nor skips anything.
        offset: state.offset + size,
        inflight: state.inflight + size,
        reconnects: 0
    }
  end

  defp ack(state, bytes), do: %{state | inflight: max(state.inflight - bytes, 0)}

  # Over the watermark: drop the exec channel and wait for the session to catch
  # up. Frames still in flight from the closing channel are discarded, not
  # delivered -- `offset` did not advance for them, so the resume re-reads them.
  defp pause(state) do
    _ = API.close_exec(state.podexec)
    await_drain(%{state | podexec: nil})
  end

  # Waiting on the session, not on a wall clock.
  #
  # The old `after @drain_timeout -> cast(:eof)` was a silent truncation of a
  # healthy session: at that moment the Pod is Running, the CLI is running, the
  # tee file is still growing, and nothing is reading it — yet the session was
  # told the stream had *ended*. A consumer that stalled for 61 seconds (a
  # blocked LiveView, a long GC pause, a slow downstream) lost the remainder of
  # its output and had no way to know.
  #
  # A monitor is the honest signal: EOF when the session is actually gone, and
  # wait as long as it takes while it is alive. `pause/1` already closed the exec
  # channel, so waiting here costs one idle process and no cluster resources —
  # the Pod's own lifetime is bounded by the session's, not by this.
  defp await_drain(%{parent: parent} = state) do
    ref = Process.monitor(state.session)

    try do
      drain_loop(state, parent, ref)
    after
      Process.demonitor(ref, [:flush])
    end
  end

  defp drain_loop(state, parent, ref) do
    receive do
      {:cc_ack, bytes} ->
        state = ack(state, bytes)

        # Resume at half the watermark rather than at zero, so a busy session
        # does not thrash between close and re-open on every chunk.
        if state.inflight <= div(state.max_inflight, 2) do
          reader_loop(state)
        else
          drain_loop(state, parent, ref)
        end

      {:DOWN, ^ref, :process, _pid, _reason} ->
        # Nobody left to deliver to. No :eof either — there is no session to
        # receive it.
        :ok

      {:EXIT, ^parent, reason} ->
        exit(reason)

      _other ->
        drain_loop(state, parent, ref)
    end
  end

  # `tail -f` never ends while the Pod lives, so a close frame or a transport
  # error means the CHANNEL dropped, not the stream -- casting :eof here (which
  # is what Docker does on `:done`) would end a live session over a blip.
  # Resume is free by construction, so reconnect instead, and only give up once
  # the Pod is confirmed gone or the reconnects stop making progress.
  defp reconnect_or_eof(state, reason) do
    # A stream that stayed open long enough to count as working clears the
    # consecutive-failure budget before it is checked.
    state = note_progress(state)
    {liveness, state} = memoized_liveness(state)

    case {state.reconnects >= @max_reconnects, liveness} do
      # Out of budget. Consecutive failures to *establish* a stream, not
      # "failures since the last byte" -- see attach_stream/2 for why that
      # distinction guaranteed idle sessions died.
      {true, _} ->
        Logger.warning(
          "Kubernetes reader giving up after #{state.reconnects} consecutive " <>
            "reconnects: #{inspect(explain(state, reason))}"
        )

        GenServer.cast(state.session, :eof)

      {false, :running} ->
        retry(state)

      # The one case that justifies ending the session.
      {false, :terminal} ->
        Logger.warning("Kubernetes reader stopped: #{inspect(explain(state, reason))}")
        GenServer.cast(state.session, :eof)

      # The API server did not answer. That is not evidence the Pod is gone, and
      # treating it as such used to end a live session over a single 429.
      {false, :unknown} ->
        Logger.debug("Kubernetes reader: pod liveness unknown, retrying")
        retry(state)
    end
  end

  # Short enough that a Pod which really went away is noticed within a second,
  # long enough to cover one reconnect burst: the first four backoffs total
  # 100 + 200 + 400 = 700 ms, so an episode asks the API server once instead of
  # five times. Necessarily far below `reap_grace_ms`, which is 60 s by default —
  # a liveness answer older than the grace window could let the reaper act on
  # stale information.
  @liveness_ttl_ms 1_000

  # Deliberately per-reader state rather than a shared cache.
  #
  # The plan called for a per-Pod cache so "N readers on one node cost one
  # request", but that premise does not hold here: one Pod carries one session
  # and one reader, so no two readers ever ask about the same Pod and there is
  # nothing for a shared table to collapse. It would add an ETS table, an owner
  # process and a global staleness window to save nothing.
  #
  # What is real is the *burst*: `reconnect_or_eof/2` is consulted once per failed
  # attempt, so one blip asked five times in about three seconds. That is what
  # this collapses.
  #
  # Steady-state volume is unchanged and is not cached away by anything: idle
  # polling is one `GET /pods/{name}` per session per `pod_poll_ms` (60 s), i.e.
  # roughly `sessions / 60` requests per second — 5 QPS at 300 concurrent
  # sessions. If that ever becomes the constraint, the answer is a watch, not a
  # cache.
  # Doc-false public so the TTL is assertable with a counting adapter rather than
  # by timing a live cluster.
  @doc false
  def memoized_liveness(state) do
    now = System.monotonic_time(:millisecond)

    if state.liveness && now - state.liveness_at < @liveness_ttl_ms do
      {state.liveness, state}
    else
      answer = liveness(state.handle)
      {answer, %{state | liveness: answer, liveness_at: now}}
    end
  end

  defp retry(state) do
    attempt = state.reconnects + 1
    # Only returns when the window elapses; a dead session exits from inside.
    state = sleep_interruptibly(state, backoff(attempt))
    reader_loop(%{state | reconnects: attempt})
  end

  # `Process.sleep/1` here made the reader deaf for up to 3.1s cumulative across
  # the five reconnect attempts -- to `{:cc_ack, _}` (so a session that resumed
  # consuming was not noticed) and, worse, to `{:EXIT, parent, _}` (so a session
  # being shut down could not take its reader with it). Waiting in `receive`
  # instead keeps both live.
  defp sleep_interruptibly(state, ms) do
    # A deadline, not a per-message timeout. Passing `ms` straight to `after` on
    # every recursion restarts the window each time a message arrives, so a
    # session acking steadily during backoff would defer the reconnect forever.
    wait_until(state, System.monotonic_time(:millisecond) + ms)
  end

  # The transport reason alone is frequently useless -- `{:close, 1000, ""}` or
  # "command terminated with non-zero exit code" tells you the channel ended,
  # not why. The container's own last words usually do, so they are attached
  # when there are any.
  #
  # stderr wins over the exec status, and the two are kept apart for a reason:
  # channel 3 always arrives *after* channel 2, so folding both into one field
  # meant the status JSON overwrote the useful line every single time. Measured
  # against a missing tee file: channel 2 carried
  # `tail: can't open '/var/log/cc/out.jsonl': No such file or directory` and
  # channel 3 then replaced it with `{"status":"Failure",…"ExitCode"…}` — so the
  # give-up line named an exit code nobody can act on and dropped the sentence
  # that says exactly what is wrong.
  defp explain(%{last_stderr: stderr}, reason) when is_binary(stderr),
    do: {reason, {:stderr, stderr}}

  defp explain(%{last_exec_error: payload}, reason) when is_binary(payload),
    do: {reason, exec_error_reason(payload)}

  defp explain(_state, reason), do: reason

  # Channel 3 is a v4 `Status`, so it is decoded rather than pasted in raw.
  # `exec_status/1` wraps every failure as `{:k8s, _}`, so there is deliberately
  # no catch-all here: one would be dead code the type checker flags.
  defp exec_error_reason(payload) do
    case API.exec_status(payload) do
      :ok -> {:exec_status, :success}
      {:error, {:k8s, reason}} -> {:exec_status, reason}
    end
  end

  defp remember_stderr(state, data) when is_binary(data) do
    # Bounded, and the *tail* rather than the head: the useful line is the last
    # one the container managed to write, and this string ends up in a log.
    trimmed = data |> String.trim() |> String.slice(-200, 200)
    if trimmed == "", do: state, else: %{state | last_stderr: trimmed}
  end

  defp remember_stderr(state, _data), do: state

  defp remember_exec_error(state, data) when is_binary(data) do
    trimmed = String.trim(data)
    if trimmed == "", do: state, else: %{state | last_exec_error: trimmed}
  end

  defp remember_exec_error(state, _data), do: state

  @doc false
  # Exposed (doc-false) for the same reason as `attach_stream/2`: both halves of
  # this are about what happens to messages that arrive *inside* a backoff
  # window, and reproducing that against a cluster would need a precisely-timed
  # socket failure. See kubernetes_unit_test.exs.
  def wait_until(%{parent: parent} = state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      state
    else
      receive do
        {:EXIT, ^parent, reason} -> exit(reason)
        {:cc_ack, bytes} -> wait_until(ack(state, bytes), deadline)
        {:stderr, data} -> wait_until(remember_stderr(state, data), deadline)
        {:error, data} -> wait_until(remember_exec_error(state, data), deadline)
        # Frames from the channel that just died, and its EXIT. Nothing to do
        # with them: `offset` never advanced, so the resume re-reads those bytes.
        _other -> wait_until(state, deadline)
      after
        remaining -> state
      end
    end
  end

  # Jittered, because the unjittered version had every reader on a node retrying
  # in lockstep: one apiserver blip disconnects N sessions simultaneously and
  # they then all reconnect at the same five instants. Full jitter over the
  # window costs nothing and spreads the retry.
  defp backoff(attempt) do
    ceiling = min(100 * Bitwise.bsl(1, attempt - 1), 2_000)
    div(ceiling, 2) + :rand.uniform(div(ceiling, 2))
  end

  # --- lifecycle ---

  @impl true
  def await_exit(%__MODULE__{pod_name: name} = handle, _timeout) when is_binary(name) do
    case API.get_pod(handle.config, name) do
      {:ok, pod} ->
        cond do
          phase(pod) == "Running" ->
            :timeout

          code = exit_code(pod) ->
            {:ok, code}

          true ->
            # An evicted or preempted Pod has a terminal phase and no container
            # status at all. That is "exited, status unknown" -- reporting
            # :timeout instead would leave the Reaper never pruning the record.
            {:ok, nil}
        end

      {:error, {:k8s, {:not_found, _}}} ->
        {:ok, nil}

      {:error, _reason} ->
        :timeout
    end
  end

  def await_exit(%__MODULE__{}, _timeout), do: :timeout

  @impl true
  def alive?(%__MODULE__{} = handle), do: liveness(handle) == :running

  @doc false
  # Tri-state, because the boolean the `Backend` callback requires cannot express
  # the difference between "the Pod is gone" and "the API server did not answer",
  # and the reader must not treat those the same.
  #
  # `alive?/1` collapsing `{:error, _}` to `false` meant one throttled or
  # timed-out liveness GET — a 429, a 500, a DNS blip — ended a live session and
  # orphaned a billed Pod. `await_exit/2` already fails *open* on the same error,
  # so the boolean was the inconsistent one.
  #
  # Only `:terminal` justifies EOF. `:unknown` means ask again later.
  @spec liveness(t()) :: :running | :terminal | :unknown
  def liveness(%__MODULE__{pod_name: name} = handle) when is_binary(name) do
    case API.get_pod(handle.config, name) do
      {:ok, pod} ->
        cond do
          # A Pod being deleted is going away even while it still reports
          # Running, and reconnecting into it just races the deletion.
          get_in(pod, ["metadata", "deletionTimestamp"]) -> :terminal
          phase(pod) == "Running" -> :running
          true -> :terminal
        end

      # 404 is the one error that genuinely means gone.
      {:error, {:k8s, {:not_found, _}}} ->
        :terminal

      {:error, _reason} ->
        :unknown
    end
  end

  def liveness(%__MODULE__{}), do: :terminal

  @impl true
  def destroy(%__MODULE__{pod_name: nil}), do: :ok

  def destroy(%__MODULE__{pod_name: name} = handle) do
    result = API.delete_pod(handle.config, name)
    _ = delete_managed_policy(handle)

    case result do
      {:ok, _} ->
        :ok

      # 404 means it is already gone, which is the desired end state. The
      # behaviour requires destroy/1 to be idempotent and Session calls it from
      # several teardown paths.
      {:error, {:k8s, {:not_found, _}}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Kubernetes destroy failed for #{name}: #{inspect(reason)}")
        :ok
    end
  end

  @impl true
  def scrub(%__MODULE__{} = handle) do
    # The handle carries the config it was provisioned from, which may include
    # :api_key and :session_token. Store records can be written to disk and
    # outlive the VM, and reattaching needs none of this -- the Pod already
    # holds whatever environment it was started with.
    %{handle | config: Store.scrub_opts(handle.config)}
  end

  @impl true
  def list_live(opts) do
    owner = opts[:owner] || Store.owner_id()

    # Scoped to this owner, never global: an unscoped list would let one node's
    # reaper destroy another node's Pods. The selector is the hash; the raw
    # owner comes back off the annotation so Reaper.owned_by?/3 can re-check it.
    selectors = [{"crowd_control.owner_hash", owner_label(owner)}]

    case API.list_all(opts, nil, label_selectors: selectors) do
      {:ok, pods} ->
        {:ok,
         pods
         |> Enum.filter(&(phase(&1) == "Running"))
         |> Enum.map(&handle_from_pod(&1, opts, owner))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_from_pod(pod, opts, owner) do
    metadata = pod["metadata"] || %{}
    labels = metadata["labels"] || %{}
    annotations = metadata["annotations"] || %{}
    container = pod |> get_in(["spec", "containers"]) |> List.wrap() |> List.first() || %{}

    %__MODULE__{
      pod_name: metadata["name"],
      namespace: metadata["namespace"],
      image: container["image"],
      tee_path: sandbox_path(annotations, opts, :tee_path, @default_tee),
      fifo_path: sandbox_path(annotations, opts, :fifo_path, @default_fifo),
      env_path: sandbox_path(annotations, opts, :env_path, @default_env),
      session_key: labels["crowd_control.session"],
      owner: annotations["crowd_control.owner"] || owner,
      config: opts
    }
  end

  # From the Pod, not from `opts`: these are facts about how this sandbox was
  # provisioned, and a byte offset is only meaningful against the file it was
  # measured in. A handle rebuilt from `opts` alone resumed a session with a
  # custom `:tee_path` against the default path — a file that does not exist.
  #
  # The `opts` fallback covers Pods that were already running when the
  # annotations shipped, and the module defaults cover the rest.
  defp sandbox_path(annotations, opts, key, default) do
    annotations["crowd_control.#{key}"] || opts[key] || default
  end

  @doc """
  Milliseconds since the Pod was created, from its label.

  `nil` when the label is missing or unparseable. `CrowdControl.Reaper` uses
  this for the grace period that keeps a mid-provision Pod from being reaped
  before its store record exists, so failing open here is deliberate.
  """
  @spec age_ms(t()) :: non_neg_integer() | nil
  def age_ms(%__MODULE__{pod_name: name} = handle) when is_binary(name) do
    case API.get_pod(handle.config, name) do
      {:ok, pod} -> parse_age(get_in(pod, ["metadata", "labels", "crowd_control.created_at"]))
      {:error, _reason} -> nil
    end
  end

  def age_ms(%__MODULE__{}), do: nil

  defp parse_age(created) when is_binary(created) do
    case Integer.parse(created) do
      {ms, ""} -> max(System.system_time(:millisecond) - ms, 0)
      _ -> nil
    end
  end

  defp parse_age(_), do: nil

  # --- network posture ---

  @doc false
  # Deliberately never infers a posture. A Kubernetes Pod always has cluster
  # networking -- there is no equivalent of Docker's `NetworkMode: "none"` -- so
  # picking one silently in exactly the scenario SECURITY.md warns about is
  # worse than refusing to start.
  @spec validate_network!(keyword()) :: :ok | {:error, term()}
  def validate_network!(config) do
    case config[:network] do
      :deny_all ->
        :ok

      {:policy, name} when is_binary(name) ->
        :ok

      :unrestricted ->
        :ok

      nil ->
        if config[:proxy_url] || config[:api_url] do
          {:error, {:k8s, :network_policy_required}}
        else
          :ok
        end

      other ->
        {:error, {:k8s, {:invalid_network, other}}}
    end
  end

  # Shape-checked here rather than at the API server, because these three land
  # in a Pod spec that is only submitted after a NetworkPolicy may already have
  # been created. A 422 at that point costs a rollback; a typo is worth
  # catching before anything exists.
  @doc false
  @spec validate_runtime!(keyword()) :: :ok | {:error, term()}
  def validate_runtime!(config) do
    with :ok <- validate_runtime_class(config[:runtime_class]),
         :ok <- validate_node_selector(config[:node_selector]) do
      validate_tolerations(config[:tolerations])
    end
  end

  defp validate_runtime_class(nil), do: :ok
  defp validate_runtime_class(name) when is_binary(name) and name != "", do: :ok
  defp validate_runtime_class(other), do: {:error, {:k8s, {:invalid_runtime_class, other}}}

  defp validate_node_selector(nil), do: :ok

  defp validate_node_selector(map) when is_map(map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      :ok
    else
      {:error, {:k8s, {:invalid_node_selector, map}}}
    end
  end

  defp validate_node_selector(other), do: {:error, {:k8s, {:invalid_node_selector, other}}}

  defp validate_tolerations(nil), do: :ok

  defp validate_tolerations(list) when is_list(list) do
    if Enum.all?(list, &is_map/1) do
      :ok
    else
      {:error, {:k8s, {:invalid_tolerations, list}}}
    end
  end

  defp validate_tolerations(other), do: {:error, {:k8s, {:invalid_tolerations, other}}}

  defp ensure_network_policy(%__MODULE__{config: config} = handle) do
    case config[:network] do
      :deny_all -> create_managed_policy(handle)
      {:policy, name} -> assert_policy_exists(config, name)
      _ -> :ok
    end
  end

  defp create_managed_policy(%__MODULE__{config: config} = handle) do
    case API.create_network_policy(config, network_policy_manifest(handle)) do
      {:ok, _} -> :ok
      # 409 means a previous provision of this exact Pod name already made it,
      # which is the desired end state.
      {:error, {:k8s, {:http_status, 409, _}}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Assert the caller's claim rather than trusting it. A named policy that does
  # not exist is a sandbox with no boundary at all.
  defp assert_policy_exists(config, name) do
    case API.get_network_policy(config, name) do
      {:ok, _} -> :ok
      {:error, {:k8s, {:not_found, _}}} -> {:error, {:k8s, {:policy_missing, name}}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Deliberately NOT gated on `config[:network] == :deny_all`, which is how this
  # leaked. A handle rebuilt by `list_live/1` carries the *caller's* config
  # (`handle_from_pod/3`), not the config the sandbox was provisioned with — so
  # every reaper-driven teardown, and every `destroy_all/1`-style cleanup, saw
  # `config[:network] == nil`, skipped this, and left the NetworkPolicy behind
  # for good.
  #
  # Unconditional is also safe rather than merely convenient: the only name this
  # can ever delete is `<pod_name>-deny-all`, which is derived from a Pod name we
  # minted, so it is ours by construction. A caller-supplied
  # `network: {:policy, name}` is never touched, and a 404 for a policy that was
  # never created is success.
  defp delete_managed_policy(%__MODULE__{config: config} = handle) do
    case API.delete_network_policy(config, policy_name(handle.pod_name)) do
      {:ok, _} -> :ok
      {:error, {:k8s, {:not_found, _}}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp policy_name(pod_name), do: pod_name <> "-deny-all"

  @doc false
  @spec network_policy_manifest(t()) :: map()
  def network_policy_manifest(%__MODULE__{} = handle) do
    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "NetworkPolicy",
      "metadata" => %{
        "name" => policy_name(handle.pod_name),
        "namespace" => handle.namespace,
        "labels" => %{
          "crowd_control.session" => handle.session_key,
          "crowd_control.owner_hash" => owner_label(handle.owner)
        }
      },
      # Empty rule lists under both policy types is the canonical deny-all: the
      # Pod is selected, so the default-allow no longer applies, and nothing is
      # permitted back in.
      "spec" => %{
        "podSelector" => %{"matchLabels" => %{"crowd_control.session" => handle.session_key}},
        "policyTypes" => ["Ingress", "Egress"]
      }
    }
  end

  # A declaration is not enforcement. Any API server accepts a NetworkPolicy
  # object; only a CNI with a policy controller acts on one. OrbStack, for
  # instance, accepts them and enforces nothing -- so a `:deny_all` sandbox
  # there would report a boundary that does not exist. Prove it once per
  # cluster, cache the answer either way, and refuse to start if it is absent.
  defp network_preflight!(%__MODULE__{config: config}) do
    cond do
      config[:network] != :deny_all -> :ok
      config[:network_probe] == false -> :ok
      true -> check_enforcement(config)
    end
  end

  defp check_enforcement(config) do
    # :persistent_term, per VM, keyed by cluster: a cluster does not grow a CNI
    # policy controller mid-run, and a VM restart re-probing once is the correct
    # cost. No supervision, free reads.
    key = {__MODULE__, :netpol_enforced, API.cluster_url(config)}

    case :persistent_term.get(key, :unknown) do
      true -> :ok
      false -> {:error, {:k8s, :network_policy_not_enforced}}
      :unknown -> probe_and_cache(config, key)
    end
  end

  defp probe_and_cache(config, key) do
    case run_enforcement_probe(config) do
      {:ok, enforced?} ->
        :persistent_term.put(key, enforced?)
        enforcement_result(enforced?)

      # Inconclusive is never cached: a probe that could not run says nothing
      # about the cluster, and caching it would make one flaky minute permanent.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enforcement_result(true), do: :ok
  defp enforcement_result(false), do: {:error, {:k8s, :network_policy_not_enforced}}

  # Guarded run first, control only when needed.
  #
  # Ordering matters for cost and for strictness. On a cluster that enforces
  # nothing the guarded fetch simply succeeds, which is conclusive on its own —
  # one Pod, no control. Only a *failed* guarded run is ambiguous, and that is
  # when the control earns its keep.
  #
  # Two independent things must both hold before enforcement is believed, because
  # each rules out a different false positive:
  #
  #   * the guarded container actually RAN and exited non-zero. A Pod that never
  #     started (scheduling, image pull) also reports phase `Failed`, and reading
  #     that as "blocked by policy" is how this reported enforcement on a cluster
  #     with no policy controller at all.
  #   * the same fetch succeeds with no policy in place. That rules out a broken
  #     network, an unreachable probe URL, and a wget that fails for its own
  #     reasons.
  #
  # Anything else is inconclusive, and inconclusive is never cached and never
  # treated as enforcement.
  defp run_enforcement_probe(config) do
    suffix = 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    # A probe that was killed rather than returning left its Pods and its
    # NetworkPolicy behind: `probe_egress/3` cleans up in `after`, and `after`
    # does not run when the process is *killed* — which is exactly what ExUnit
    # does on a timeout, and what a supervisor does on a shutdown. Nothing else
    # would ever remove them: the objects carry no owner hash, so neither the
    # Reaper nor any owner-scoped cleanup can match them.
    #
    # Sweeping here rather than in the `after` block is deliberate: the next probe
    # is the first moment we know the previous one is over.
    _ = sweep_stale_probes(config)

    with {:ok, guarded} <- probe_egress(config, "cc-netpol-probe-" <> suffix, policy?: true) do
      classify_guarded(config, suffix, guarded)
    end
  end

  # Only objects older than this are swept. A probe takes seconds, so anything
  # this old is abandoned — and the floor is what keeps one node's sweep from
  # deleting another node's probe out from under it while it is reading phases.
  @probe_stale_ms 300_000

  defp sweep_stale_probes(config) do
    case API.list_all(config, nil, label_selectors: [{"crowd_control.probe_sweep", "true"}]) do
      {:ok, pods} ->
        for pod <- pods,
            name = get_in(pod, ["metadata", "name"]),
            is_binary(name),
            stale_probe?(pod) do
          Logger.info("Kubernetes: sweeping abandoned network probe #{name}")
          _ = API.delete_pod(config, name)
          _ = API.delete_network_policy(config, name)
        end

        :ok

      # Fail open. A sweep that cannot list says nothing about the cluster, and
      # refusing to probe because housekeeping failed would turn a cleanup
      # problem into a provisioning outage.
      {:error, _reason} ->
        :ok
    end
  end

  defp stale_probe?(pod) do
    case parse_age(get_in(pod, ["metadata", "labels", "crowd_control.created_at"])) do
      nil -> false
      age -> age >= @probe_stale_ms
    end
  end

  defp classify_guarded(config, suffix, guarded) do
    if needs_control?(guarded) do
      case probe_egress(config, "cc-netpol-ctl-" <> suffix, policy?: false) do
        {:ok, control} -> probe_verdict(guarded, control)
        {:error, reason} -> {:error, reason}
      end
    else
      probe_verdict(guarded, nil)
    end
  end

  # A guarded run that is conclusive on its own does not spend a second Pod: the
  # fetch either went through (nothing is enforcing) or the container never ran
  # (the result says nothing about the network either way).
  defp needs_control?(%{phase: "Succeeded"}), do: false
  defp needs_control?(%{ran?: false}), do: false
  defp needs_control?(_guarded), do: true

  @doc false
  # The probe's entire decision, separated from the two Pod runs so that all four
  # outcomes are assertable without a cluster — a watch stream cannot be stubbed
  # through the `:req_adapter` seam, which is why this used to be live-only and
  # therefore effectively untested.
  #
  # `nil` control means one was not needed.
  @spec probe_verdict(map(), map() | nil) :: {:ok, boolean()} | {:error, term()}
  def probe_verdict(%{phase: "Succeeded"}, _control), do: {:ok, false}

  def probe_verdict(%{ran?: false}, _control) do
    {:error, {:k8s, {:network_probe_inconclusive, :probe_never_ran}}}
  end

  # Blocked, and the identical fetch succeeded without the policy. This is the
  # only path that reports enforcement.
  def probe_verdict(_guarded, %{phase: "Succeeded"}), do: {:ok, true}

  def probe_verdict(_guarded, _control) do
    {:error, {:k8s, {:network_probe_inconclusive, :control_failed}}}
  end

  defp probe_egress(config, name, opts) do
    namespace = API.namespace(config)
    pod = probe_manifest(name, namespace, config)

    try do
      # The probe's PID 1 *is* the egress attempt, so its exit status is the
      # answer: Succeeded means the fetch went through, Failed means it did not.
      with :ok <- maybe_create_probe_policy(config, name, namespace, opts[:policy?]),
           {:ok, _} <- API.create_pod(config, pod),
           {:ok, phase} <- await_probe_phase(config, name) do
        {:ok, %{phase: phase, ran?: probe_ran?(config, name)}}
      end
    after
      _ = API.delete_pod(config, name)
      if opts[:policy?], do: API.delete_network_policy(config, name)
    end
  end

  # Did the container get far enough to exit on its own? A `terminated` state
  # means it ran; `waiting` means it never did.
  defp probe_ran?(config, name) do
    case API.get_pod(config, name) do
      {:ok, pod} ->
        pod
        |> get_in(["status", "containerStatuses"])
        |> List.wrap()
        |> Enum.any?(&get_in(&1, ["state", "terminated"]))

      {:error, _reason} ->
        false
    end
  end

  defp maybe_create_probe_policy(_config, _name, _namespace, false), do: :ok

  defp maybe_create_probe_policy(config, name, namespace, true) do
    case API.create_network_policy(config, probe_policy_manifest(name, namespace)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_probe_phase(config, name) do
    timeout = config[:provision_timeout] || @default_provision_timeout

    task =
      Task.async(fn ->
        API.wait_until(config, name, &probe_settled?/1, timeout)
      end)

    case Task.yield(task, timeout + 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, _} ->
        case API.get_pod(config, name) do
          {:ok, pod} when is_map_key(pod, "status") ->
            probe_phase(phase(pod))

          {:ok, _} ->
            {:error, {:k8s, {:network_probe_failed, :no_status}}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, {:k8s, {:network_probe_failed, :timeout}}}
    end
  end

  defp probe_phase(phase) when phase in ["Succeeded", "Failed"], do: {:ok, phase}
  defp probe_phase(other), do: {:error, {:k8s, {:network_probe_failed, other}}}

  defp probe_settled?(:deleted), do: true

  defp probe_settled?(pod) do
    phase(pod) in ["Succeeded", "Failed"] or waiting_reason(pod) in @fatal_waiting
  end

  defp probe_policy_manifest(name, namespace) do
    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "NetworkPolicy",
      "metadata" => %{"name" => name, "namespace" => namespace},
      "spec" => %{
        "podSelector" => %{"matchLabels" => %{"crowd_control.probe" => name}},
        "policyTypes" => ["Ingress", "Egress"]
      }
    }
  end

  @doc false
  # Public so the probe's labels and its egress command are assertable without a
  # cluster: the probe creates Pods and then waits on a watch stream, and a watch
  # cannot be stubbed through the `:req_adapter` seam.
  @spec probe_manifest(String.t(), String.t(), keyword()) :: map()
  def probe_manifest(name, namespace, config) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        # Two labels, two jobs. The name-valued one is what this probe's own
        # NetworkPolicy selects, so it must stay unique per probe. The constant
        # one is what `sweep_stale_probes/1` selects on, since a selector cannot
        # ask for "any value"; `created_at` is what tells the sweep whether a
        # probe is abandoned or merely someone else's, in flight right now.
        "labels" => %{
          "crowd_control.probe" => name,
          "crowd_control.probe_sweep" => "true",
          "crowd_control.created_at" => to_string(System.system_time(:millisecond))
        }
      },
      "spec" => %{
        "restartPolicy" => "Never",
        "automountServiceAccountToken" => false,
        "enableServiceLinks" => false,
        "containers" => [
          %{
            "name" => "probe",
            "image" => config[:network_probe_image] || @default_probe_image,
            "command" => ["/bin/sh", "-c", probe_script(config)],
            "securityContext" => %{
              "allowPrivilegeEscalation" => false,
              "capabilities" => %{"drop" => ["ALL"]}
            }
          }
        ]
      }
    }
  end

  # A TCP connect to the API server, and deliberately nothing more ambitious.
  #
  # The probe used to `wget http://1.1.1.1`, which made a *security* decision
  # depend on the internet: a slow link or a dropped packet inside the 5s window
  # failed the guarded run, and a failed guarded run reads as "policy stopped
  # it". That direction of error is the dangerous one, and it was observed —
  # this reported enforcement on a cluster with no policy controller at all.
  #
  # The API server's ClusterIP is reachable from every Pod on a working cluster
  # by construction, and `KUBERNETES_SERVICE_HOST` is injected by the kubelet
  # even with `enableServiceLinks: false` (verified). So: no DNS, no TLS, no
  # internet, no name resolution — one TCP handshake, which is exactly what a
  # deny-all egress policy blocks and nothing else plausibly does.
  #
  # `:network_probe_url` remains for callers who specifically want to prove
  # *internet* egress is blocked. It is the less deterministic choice and the
  # control run is what keeps it honest.
  defp probe_script(config) do
    case config[:network_probe_url] do
      nil ->
        ~S|nc -z -w 5 "$KUBERNETES_SERVICE_HOST" "${KUBERNETES_SERVICE_PORT:-443}"|

      url ->
        "wget -q -O- -T 5 #{Shell.escape(url)} >/dev/null 2>&1"
    end
  end

  # --- Private ---

  defp phase(pod), do: get_in(pod, ["status", "phase"])

  # Both status lists, init first.
  #
  # This was a real misdiagnosis: the init container shares the sandbox image, so
  # an unpullable image fails on the *init* container and its status lands in
  # `initContainerStatuses` while `containerStatuses` is still absent. Reading
  # only the latter meant `settled?/1` never saw `ImagePullBackOff`, the watch
  # never settled, and a broken image reference surfaced as a 25-second
  # `:provision_timeout` instead of an immediate `{:pod_not_ready,
  # "ImagePullBackOff"}`. Init first because it runs first, so its failure is
  # both the earlier and the more specific one.
  defp waiting_reason(pod), do: waiting_field(pod, "reason")

  defp waiting_message(pod), do: waiting_field(pod, "message")

  defp waiting_field(pod, field) do
    ["initContainerStatuses", "containerStatuses"]
    |> Enum.flat_map(&(pod |> get_in(["status", &1]) |> List.wrap()))
    |> Enum.find_value(fn status -> get_in(status, ["state", "waiting", field]) end)
  end

  defp exit_code(pod) do
    pod
    |> get_in(["status", "containerStatuses"])
    |> List.wrap()
    |> List.first()
    |> case do
      nil -> nil
      status -> get_in(status, ["state", "terminated", "exitCode"])
    end
  end

  defp resolve_namespace(opts) do
    {:ok, API.namespace(opts)}
  rescue
    e -> {:error, {:k8s, {:exception, Exception.message(e)}}}
  end

  defp fetch_image(opts) do
    case opts[:image] do
      image when is_binary(image) and image != "" -> {:ok, image}
      _ -> {:error, {:k8s, :image_required}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_kubereq! do
    if Code.ensure_loaded?(Kubereq) do
      :ok
    else
      raise """
      CrowdControl.Backend.Kubernetes requires the optional :kubereq dependency.

      Add it to your deps:

          {:kubereq, "~> 0.4.4"}
      """
    end
  end
end
