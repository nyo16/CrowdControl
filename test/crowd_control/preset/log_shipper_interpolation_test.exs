defmodule CrowdControl.Preset.LogShipperInterpolationTest do
  # The LogShipper config is literal: a label value or a custom filter may
  # contain `$VAR` or `${VAR}`, and Vector must neither substitute the
  # environment into it (a filter would stop matching, a label would carry the
  # sidecar's environment to the sink) nor fail on it. Vector 0.61 interpolates
  # only with --dangerously-allow-env-var-interpolation (or its environment
  # variable), and the preset sets neither. Needs a Docker daemon:
  #
  #     mix test --only vector
  #
  # The same `vector test` is run once more with interpolation turned on, so
  # the fixture is shown to notice it.
  use ExUnit.Case, async: true

  alias CrowdControl.Preset.LogShipper
  alias CrowdControl.Preset.YAML

  @moduletag :vector
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @label "${HOME}$HOME"
  @token "tok_$HOME"
  @opts [
    sink: :console,
    capture_volume: "cclog",
    labels: %{"team" => @label},
    redact: [{:regex, ~S"tok_\$HOME"}]
  ]

  setup %{tmp_dir: tmp_dir} do
    if System.find_executable("docker") == nil, do: flunk("the :vector tests need docker on PATH")

    File.write!(Path.join(tmp_dir, "vector.yaml"), LogShipper.config(@opts))
    File.write!(Path.join(tmp_dir, "tests.yaml"), YAML.encode([{"tests", [literal_test()]}]))
    :ok
  end

  test "the preset's Vector reads $VAR and ${VAR} in labels and filters literally",
       %{tmp_dir: tmp_dir} do
    spec = LogShipper.spec(@opts)

    {output, status} = vector(tmp_dir, spec, ["validate", "--no-environment", config()])
    assert status == 0, "validate failed:\n#{output}"

    {output, status} = vector(tmp_dir, spec, ["test", config(), tests()])
    assert status == 0, "Vector interpolated the config:\n#{output}"
    assert output =~ ~r/^test .+ \.\.\. passed$/m

    {output, status} =
      vector(tmp_dir, spec, [
        "--dangerously-allow-env-var-interpolation",
        "test",
        config(),
        tests()
      ])

    assert status != 0, "the fixture does not detect interpolation:\n#{output}"
  end

  # Every `$` in tests.yaml is behind base64, so the expectations and the input
  # line stay literal even when Vector interpolates the files it loads.
  defp literal_test do
    line = JSON.encode!(%{"type" => "assistant", "text" => "here: " <> @token})

    [
      {"name", "labels and filters are literal"},
      {"inputs",
       [
         [
           {"insert_at", "transcript_redacted"},
           {"type", "vrl"},
           {"source", ".message = decode_base64!(#{b64(line)})\n.offset = 0"}
         ]
       ]},
      {"outputs",
       [
         [
           {"extract_from", "transcript_redacted"},
           {"conditions",
            [
              [
                {"type", "vrl"},
                {"source",
                 {:block,
                  """
                  assert_eq!(.cc.labels.team, decode_base64!(#{b64(@label)}))
                  assert!(!contains(encode_json(.), decode_base64!(#{b64(@token)})), "leaked")
                  """}}
              ]
            ]}
         ]
       ]}
    ]
  end

  defp b64(text), do: JSON.encode!(Base.encode64(text))

  defp config, do: "/etc/vector/vector.yaml"
  defp tests, do: "/etc/vector/tests.yaml"

  # The preset's own image and environment, so an image default or a preset
  # env var that turned interpolation on would fail here.
  defp vector(dir, spec, args) do
    env = Enum.flat_map(spec.env, fn {key, value} -> ["-e", "#{key}=#{value}"] end)

    System.cmd(
      "docker",
      ["run", "--rm", "-v", "#{dir}:/etc/vector:ro"] ++ env ++ [spec.image | args],
      stderr_to_stdout: true
    )
  end
end
