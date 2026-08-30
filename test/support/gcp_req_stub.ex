defmodule CrowdControl.GcpReqStub do
  @moduledoc false
  # Routes `gcp_compute`'s Req calls through a `{method, path} -> {status, body}`
  # function and records every request, so `CrowdControl.Provider.Gce` can be
  # tested with no credentials, no network, and no `gcloud`.
  #
  # `gcp_compute` ships an equivalent helper, but its hex package excludes
  # `test/`, so this is a re-implementation rather than a wrapper. Same spirit
  # as `respond/2` in test/crowd_control/provider/docker_unit_test.exs: an
  # unrouted call raises with the method and path, so a test that stubs the
  # wrong thing fails loudly instead of hanging or hitting the internet.
  #
  #     {config, stub} =
  #       GcpReqStub.new(fn
  #         {:post, "/projects/cc-test/zones/us-central1-a/instances"} ->
  #           {200, GcpReqStub.operation()}
  #
  #         {:get, "/projects/cc-test/zones/us-central1-a/instances/cc-sbx-x"} ->
  #           {200, GcpReqStub.instance("cc-sbx-x")}
  #       end)
  #
  #     GcpCompute.Instances.get(config, "cc-sbx-x")
  #     GcpReqStub.calls(stub)    # => [{:get, "/projects/.../instances/cc-sbx-x"}]
  #     GcpReqStub.bodies(stub)   # => [%{...decoded JSON...}]

  @project "cc-test"
  @zone "us-central1-a"

  # An unroutable host with an explicit base path, so a stub that somehow lost
  # its adapter fails fast instead of reaching compute.googleapis.com.
  @base_path "/compute/v1"
  @base_url "http://gcp.invalid#{@base_path}"

  @spec project() :: String.t()
  def project, do: @project

  @spec zone() :: String.t()
  def zone, do: @zone

  @doc "Path of `instances.insert` / `instances.list`, relative to the base URL."
  @spec instances_path() :: String.t()
  def instances_path, do: "/projects/#{@project}/zones/#{@zone}/instances"

  @doc "Path of one instance."
  @spec instance_path(String.t()) :: String.t()
  def instance_path(name), do: "#{instances_path()}/#{name}"

  @doc """
  A `%GcpCompute.Config{}` wired to `router`, plus the recorder agent.

  `opts` override the config (`:project`, `:zone`, …). `:req_options` is merged
  into the stub's own rather than replacing it, so the adapter cannot be lost by
  accident.
  """
  @spec new(fun(), keyword()) :: {struct(), pid()}
  def new(router, opts \\ []) when is_function(router, 1) do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    adapter = fn request ->
      Agent.update(recorder, &[request | &1])
      respond(request, router)
    end

    {extra_req_options, opts} = Keyword.pop(opts, :req_options, [])

    config =
      GcpCompute.Config.local!(
        Keyword.merge(
          [
            project: @project,
            zone: @zone,
            base_url: @base_url,
            # retry: false, exactly as the production clients do it: Req's
            # default :safe_transient turns a stubbed 503 into 1s + 2s + 4s of
            # sleeping, and makes a hermetic test behave unlike the code it
            # exists to exercise.
            req_options: Keyword.merge([retry: false, adapter: adapter], extra_req_options)
          ],
          opts
        )
      )

    {config, recorder}
  end

  @doc "Every recorded request, oldest first."
  @spec requests(pid()) :: [struct()]
  def requests(recorder), do: Agent.get(recorder, &Enum.reverse(&1))

  @doc "Every recorded `{method, path}`, oldest first."
  @spec calls(pid()) :: [{atom(), String.t()}]
  def calls(recorder) do
    Enum.map(requests(recorder), &{&1.method, path(&1)})
  end

  @doc "Decoded JSON bodies of every recorded request that had one."
  @spec bodies(pid()) :: [map()]
  def bodies(recorder) do
    recorder
    |> requests()
    |> Enum.flat_map(fn request ->
      case body(request) do
        nil -> []
        body -> [body]
      end
    end)
  end

  @doc "Query params of the recorded request at `index` (0-based)."
  @spec params(pid(), non_neg_integer()) :: map()
  def params(recorder, index) do
    request = recorder |> requests() |> Enum.at(index)

    case URI.parse(to_string(request.url)).query do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  # --- response bodies ---

  @doc "A `zoneOperations` resource. `DONE` by default, so no `wait` follows."
  @spec operation(String.t(), map()) :: map()
  def operation(status \\ "DONE", overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "compute#operation",
        "name" => "operation-cc-test",
        "status" => status,
        "operationType" => "insert",
        "zone" => self_link("zones/#{@zone}")
      },
      overrides
    )
  end

  @doc """
  An `instance` resource.

  Options: `:status`, `:labels`, `:metadata` (a plain map, expanded into
  `metadata.items`), `:external_ip`, `:internal_ip`, `:created_at`.
  """
  @spec instance(String.t(), keyword()) :: map()
  def instance(name, opts \\ []) do
    %{
      "kind" => "compute#instance",
      "id" => "1234567890",
      "name" => name,
      "status" => Keyword.get(opts, :status, "RUNNING"),
      "machineType" => self_link("zones/#{@zone}/machineTypes/e2-micro"),
      "zone" => self_link("zones/#{@zone}"),
      "selfLink" => self_link("zones/#{@zone}/instances/#{name}"),
      "creationTimestamp" => Keyword.get(opts, :created_at, "2026-08-30T12:00:00.000-07:00"),
      "labels" => Keyword.get(opts, :labels, %{}),
      "metadata" => %{
        "kind" => "compute#metadata",
        "items" =>
          opts
          |> Keyword.get(:metadata, %{})
          |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end)
      },
      "networkInterfaces" => [network_interface(opts)]
    }
  end

  defp network_interface(opts) do
    base = %{"name" => "nic0", "networkIP" => Keyword.get(opts, :internal_ip, "10.128.0.2")}

    case Keyword.get(opts, :external_ip, "203.0.113.10") do
      nil ->
        base

      ip ->
        Map.put(base, "accessConfigs", [
          %{"type" => "ONE_TO_ONE_NAT", "name" => "External NAT", "natIP" => ip}
        ])
    end
  end

  @doc "An `instances.list` page. `token` becomes `nextPageToken`."
  @spec list_page([map()], String.t() | nil) :: map()
  def list_page(items, token \\ nil) do
    body = %{"kind" => "compute#instanceList", "items" => items}

    if token, do: Map.put(body, "nextPageToken", token), else: body
  end

  @doc "The standard Google error envelope."
  @spec error(non_neg_integer(), String.t()) :: map()
  def error(code, message) do
    %{
      "error" => %{
        "code" => code,
        "message" => message,
        "errors" => [%{"message" => message, "reason" => "cc-test"}]
      }
    }
  end

  # --- private ---

  # A router returns `{status, body}`, or an exception to signal a transport
  # failure -- which is how Req reports one: the exception replaces the
  # response rather than arriving as an {:error, _} tuple.
  defp respond(request, router) do
    key = {request.method, path(request)}

    result =
      try do
        router.(key)
      rescue
        FunctionClauseError ->
          reraise RuntimeError.exception("unstubbed GCP Compute API call: #{inspect(key)}"),
                  __STACKTRACE__
      end

    case result do
      {status, body} -> {request, Req.Response.new(status: status, body: body)}
      exception when is_exception(exception) -> {request, exception}
    end
  end

  defp path(request) do
    case URI.parse(to_string(request.url)).path do
      @base_path <> rest -> rest
      other -> other
    end
  end

  defp body(%{options: %{json: json}}), do: JSON.decode!(JSON.encode!(json))
  defp body(%{body: body}) when is_binary(body) and body != "", do: JSON.decode!(body)
  defp body(_request), do: nil

  defp self_link(suffix) do
    "https://www.googleapis.com/compute/v1/projects/#{@project}/#{suffix}"
  end
end
