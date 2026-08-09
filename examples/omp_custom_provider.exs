# Point omp at a self-hosted OpenAI-compatible endpoint (vLLM, LiteLLM, a
# gateway) instead of a hosted provider. Demonstrates `:custom_provider`.
#
#   VLLM_BASE_URL=http://10.0.0.5:8000/v1 mix run examples/omp_custom_provider.exs
#
# Set VLLM_MODEL to the model id your server serves; set VLLM_KEY if it needs
# a bearer token.

base_url = System.get_env("VLLM_BASE_URL", "http://127.0.0.1:8000/v1")
model_id = System.get_env("VLLM_MODEL", "Qwen/Qwen3-Coder-30B")

provider =
  [base_url: base_url]
  |> then(fn spec ->
    case System.get_env("VLLM_KEY") do
      nil -> spec
      key -> Keyword.put(spec, :api_key, key)
    end
  end)

# The rendered models.yml -- worth printing once, since this is the file omp
# actually reads. The api key, if any, is referenced by env var name only.
IO.puts("models.yml:\n  #{CrowdControl.Agent.Omp.render_models_config!(provider)}\n")

# --- One session against the endpoint ---

result =
  CrowdControl.run("In one sentence: what is OTP?",
    agent: :omp,
    custom_provider: provider,
    # "vllm" is the default provider id, so the model is addressed as vllm/<id>
    model: "vllm/#{model_id}",
    approval_mode: "yolo",
    no_session_persistence: true,
    timeout: 180_000
  )

case result do
  {:result, "success", r} ->
    IO.puts("#{r["result"]}")
    IO.puts("(#{r["num_turns"]} turn(s))")

  {:result, subtype, r} ->
    IO.puts("failed (#{subtype}): #{inspect(r["result"])}")

  other ->
    IO.puts("failed: #{inspect(other)}")
end

# --- Fan out across two endpoints, collected uniformly ---
#
# Sessions sharing one spec share one generated agent directory, so this writes
# a single models.yml no matter how wide the fan-out gets.

second = System.get_env("VLLM_BASE_URL_2")

if second do
  results =
    CrowdControl.run_many("Name one BEAM strength.", [
      [
        agent: :omp,
        custom_provider: provider,
        model: "vllm/#{model_id}",
        approval_mode: "yolo",
        timeout: 180_000
      ],
      [
        agent: :omp,
        custom_provider: [base_url: second],
        model: "vllm/#{model_id}",
        approval_mode: "yolo",
        timeout: 180_000
      ]
    ])

  case results do
    {:timeout, partial} ->
      IO.puts("only #{length(partial)} of 2 finished in time")

    results when is_list(results) ->
      Enum.each(results, fn {pid, {:result, _, %{"result" => text}}} ->
        IO.puts("--- #{inspect(pid)} ---")
        IO.puts(text)
      end)
  end
end
