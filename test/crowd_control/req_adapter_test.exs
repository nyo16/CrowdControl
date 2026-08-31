defmodule CrowdControl.ReqAdapterTest do
  use ExUnit.Case, async: true

  alias CrowdControl.ReqAdapter

  doctest CrowdControl.ReqAdapter

  defmodule ModuleAdapter do
    @moduledoc false
    def run(request), do: {request, Req.Response.new(status: 204, body: "from the module")}
  end

  describe "new/1" do
    test "a function adapter is invoked, and its response is the response" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:ran, request.url.path})
        {request, Req.Response.new(status: 201, body: "made up")}
      end

      request = ReqAdapter.new(url: "http://cc.invalid/v1/thing", adapter: adapter)

      # The property the whole indirection exists for: `Req.Request.adapter/1`
      # warns for anything that is not a module, so what lands on the struct
      # must be one.
      assert request.adapter == ReqAdapter
      assert {:ok, %{status: 201, body: "made up"}} = Req.request(request)
      assert_received {:ran, "/v1/thing"}
    end

    test "an exception from a function adapter stays an error, not a response" do
      adapter = fn request -> {request, %Req.TransportError{reason: :econnrefused}} end

      result =
        [url: "http://cc.invalid/", adapter: adapter, retry: false]
        |> ReqAdapter.new()
        |> Req.request()

      assert {:error, %Req.TransportError{reason: :econnrefused}} = result
    end

    test "a module adapter is honoured as itself, with no indirection" do
      request = ReqAdapter.new(url: "http://cc.invalid/", adapter: ModuleAdapter)

      assert request.adapter == ModuleAdapter
      refute Map.has_key?(request.options, :cc_adapter)
      assert {:ok, %{status: 204, body: "from the module"}} = Req.request(request)
    end

    test "no adapter leaves Req's own" do
      assert ReqAdapter.new(url: "http://cc.invalid/").adapter == Req.Finch
    end

    test "every other option is still Req's, untouched" do
      request =
        ReqAdapter.new(
          base_url: "http://cc.invalid",
          url: "/v1/thing",
          retry: false,
          adapter: fn request -> {request, Req.Response.new(status: 200)} end
        )

      assert request.options.base_url == "http://cc.invalid"
      assert request.options.retry == false
      assert to_string(request.url) == "/v1/thing"
    end
  end

  describe "put/2" do
    test "nil leaves the request untouched" do
      request = Req.new(url: "http://cc.invalid/")

      assert ReqAdapter.put(request, nil) == request
    end

    test "a function is carried in an option, never installed as the adapter" do
      adapter = fn request -> {request, Req.Response.new(status: 200)} end

      request = Req.new(url: "http://cc.invalid/") |> ReqAdapter.put(adapter)

      assert request.adapter == ReqAdapter
      assert request.options.cc_adapter == adapter
    end

    test "installs on a request something else built" do
      adapter = fn request -> {request, Req.Response.new(status: 200, body: "late")} end

      request =
        [receive_timeout: 1_000]
        |> Req.new()
        |> ReqAdapter.put(adapter)
        |> Req.merge(url: "http://cc.invalid/")

      assert {:ok, %{status: 200, body: "late"}} = Req.request(request)
    end
  end

  describe "req_options/1" do
    test "nil is no options at all" do
      assert ReqAdapter.req_options(nil) == []
    end

    test "an adapter rides under Req's own key" do
      adapter = fn request -> {request, Req.Response.new(status: 200)} end

      assert ReqAdapter.req_options(adapter) == [adapter: adapter]
      assert ReqAdapter.req_options(ModuleAdapter) == [adapter: ModuleAdapter]
    end
  end

  describe "run/1" do
    test "hands back exactly what the carried function returned" do
      response = Req.Response.new(status: 418, body: "teapot")
      request = ReqAdapter.new(adapter: fn request -> {request, response} end)

      assert ReqAdapter.run(request) == {request, response}
    end

    test "an exception is passed through unchanged" do
      error = %Req.TransportError{reason: :timeout}
      request = ReqAdapter.new(adapter: fn request -> {request, error} end)

      assert ReqAdapter.run(request) == {request, error}
    end
  end
end
