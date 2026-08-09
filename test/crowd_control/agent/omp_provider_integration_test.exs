defmodule CrowdControl.Agent.OmpProviderIntegrationTest do
  @moduledoc """
  Drives a real `omp --mode rpc` process against a fake OpenAI-compatible
  server, proving the generated `models.yml` actually routes a session at a
  custom endpoint. Everything else about custom providers is unit-tested; this
  is the one test that shows omp reads and honors the file.

  Needs the `omp` binary and a loopback socket, so it is excluded by default:

      mix test --include omp
  """

  use ExUnit.Case, async: false

  alias CrowdControl.Agent.Omp
  alias CrowdControl.{FakeOpenAIServer, Session, TestHelpers}

  @moduletag :omp
  @model "fake/vllm-model"

  setup do
    unless System.find_executable("omp") do
      raise "the :omp tests need the omp binary on PATH (https://omp.sh/)"
    end

    :ok
  end

  test "a keyless custom provider routes the turn at the fake endpoint" do
    {:ok, server} = start_supervised({FakeOpenAIServer, model: @model})
    base_url = FakeOpenAIServer.base_url(server)

    result = run_turn("hello custom provider", base_url: base_url)

    assert {:result, "success", %{"result" => text}} = result
    assert text == "echo: hello custom provider"

    paths = server |> FakeOpenAIServer.requests() |> Enum.map(&elem(&1, 0))
    assert Enum.any?(paths, &String.ends_with?(&1, "/models")), "expected model discovery"
    assert Enum.any?(paths, &String.ends_with?(&1, "/chat/completions"))
  end

  test "an api_key reaches the endpoint as a bearer token without touching disk or argv" do
    key = "vllm-secret-#{System.unique_integer([:positive])}"
    {:ok, server} = start_supervised({FakeOpenAIServer, model: @model, api_key: key})
    base_url = FakeOpenAIServer.base_url(server)

    spec = [base_url: base_url, api_key: key]

    # The server rejects anything without the bearer token, so a successful turn
    # is itself proof the key arrived.
    assert {:result, "success", %{"result" => "echo: authed"}} = run_turn("authed", spec)

    assert Enum.all?(FakeOpenAIServer.requests(server), fn {_path, auth} ->
             auth == "Bearer #{key}"
           end)

    # ...and it got there without being written into models.yml or argv.
    dir = Omp.provider_dir!(spec)
    on_exit(fn -> Omp.remove_provider_dir(dir) end)

    refute dir |> Path.join("models.yml") |> File.read!() |> String.contains?(key)

    {_exe, args, _env} = Omp.build_command(custom_provider: spec)
    refute Enum.any?(args, &String.contains?(&1, key))
  end

  defp run_turn(prompt, spec) do
    {:ok, pid} =
      Session.start_link(
        agent: :omp,
        custom_provider: spec,
        model: "vllm/#{@model}",
        approval_mode: "yolo",
        no_session_persistence: true,
        timeout: 60_000,
        prompt: prompt
      )

    on_exit(fn -> TestHelpers.stop_session(pid) end)
    Session.subscribe(pid)

    receive do
      {:crowd_control, ^pid, {:result, _, _} = result} -> result
    after
      60_000 -> flunk("no result; messages: #{inspect(Session.get_messages(pid), limit: 5)}")
    end
  end
end
