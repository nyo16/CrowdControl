defmodule CrowdControl.ReqAdapter do
  @moduledoc """
  The one `Req` adapter in this codebase, and the carrier for the `:req_adapter`
  test seam.

  `Req` 0.7 deprecated setting `:adapter` to a function: Req.Request.adapter/1
  now `IO.warn`s on every request whose adapter is not a module. The seam this
  library exposes to tests (`:req_adapter` in a backend config, `:adapter` in
  `CrowdControl.Provider.Endpoint`'s `req_options`) is necessarily a *function*
  — a stub closes over the test's own pid, options and recorder, which no module
  name can — so the function is carried in a registered option instead and this
  module is the adapter that invokes it.

  Every module that hands options to `Req` goes through `new/1`, which is what
  makes "no function ever reaches `Req`'s `:adapter`" a property of one file
  rather than of every call site.

      iex> stub = fn request -> {request, Req.Response.new(status: 200)} end
      iex> CrowdControl.ReqAdapter.new(adapter: stub).adapter
      CrowdControl.ReqAdapter

  A module adapter needs no indirection and is passed straight through, so
  `Req`'s own adapters (and a test's, if it has one) still work.
  """

  # :req is an optional dependency, so this module must still COMPILE without
  # it: no %Req.Request{} struct patterns anywhere below (struct expansion needs
  # the module at compile time; plain map patterns do not), same rule as
  # CrowdControl.Backend.Docker.API.
  @compile {:no_warn_undefined, Req}

  @typedoc "The seam: a `Req` adapter function, an adapter module, or nothing."
  @type t ::
          (Req.Request.t() -> {Req.Request.t(), Req.Response.t() | Exception.t()})
          | module()
          | nil

  @doc """
  Build a `%Req.Request{}` from `options`, moving a function `:adapter` behind
  this module.

  Replaces `Req.request(options)`'s implicit `Req.new/1`: pass the result to
  `Req.request/1`.
  """
  @spec new(keyword()) :: Req.Request.t()
  def new(options) when is_list(options) do
    {adapter, options} = Keyword.pop(options, :adapter)

    options |> Req.new() |> put(adapter)
  end

  @doc """
  Install `adapter` on an already-built request.

  For the callers that cannot use `new/1` because something else builds the
  request — `Req.new/1` followed by a plugin's `attach/2`.
  """
  @spec put(Req.Request.t(), t()) :: Req.Request.t()
  def put(request, nil), do: request

  def put(request, module) when is_atom(module) do
    Req.merge(request, adapter: module)
  end

  def put(request, fun) when is_function(fun, 1) do
    request
    |> Req.Request.register_options([:cc_adapter])
    |> Req.merge(adapter: __MODULE__, cc_adapter: fun)
  end

  @doc """
  `adapter` as `Req` options, for a config or endpoint that carries them.

  `[]` for `nil`, so a caller has nothing to branch on. The function is left as
  a plain `:adapter` here rather than translated: these options are data on
  their way to `new/1`, which is the only thing that hands them to `Req`.
  """
  @spec req_options(t()) :: keyword()
  def req_options(nil), do: []
  def req_options(adapter), do: [adapter: adapter]

  @doc """
  The `Req` adapter callback: invoke the carried function.

  Returns whatever it returns — `{request, response}` or `{request, exception}`,
  which is the contract `Req` enforces on any adapter.
  """
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%{options: %{cc_adapter: fun}} = request), do: fun.(request)
end
