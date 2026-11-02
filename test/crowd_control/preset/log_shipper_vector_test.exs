defmodule CrowdControl.Preset.LogShipperVectorTest do
  # Runs the rendered configuration through the real Vector, so the YAML, the
  # VRL and every redaction regex are checked by the program that will execute
  # them — with no cluster and no sink. Needs a Docker daemon:
  #
  #     mix test --only vector
  #
  # `vector validate` compiles every variant; `vector test` feeds one fixture
  # line per default filter through the remap, both raw and JSON-escaped one
  # level deep (a tool result carrying JSON), and asserts the secret is gone
  # and the line still parses.
  use ExUnit.Case, async: true

  alias CrowdControl.Preset.LogShipper
  alias CrowdControl.Preset.YAML

  @moduletag :vector
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @image "timberio/vector:0.61.0-distroless-libc"

  @aggregator %{ip_block: "10.96.0.9/32"}

  @variants [
    console: [sink: :console, capture_volume: "cclog", labels: %{"team" => "platform"}],
    http_with_proxy_log: [
      sink: {:http, uri: "https://logs.example.com/ingest"},
      capture_volume: "cclog",
      proxy_log_volume: "ccproxylog"
    ],
    loki_full_redactor: [
      sink: {:loki, endpoint: "http://loki:3100"},
      capture_volume: "cclog",
      redactor: :full
    ],
    kubernetes_aggregator: [
      placement: :pod,
      sink: {:vector, address: "http://10.96.0.9:6000"},
      aggregator: @aggregator,
      redactor: {:text, "[REDACTED]"}
    ],
    unredacted: [sink: :console, capture_volume: "cclog", redact: false, ship_unredacted: true]
  ]

  # One secret per default filter, in the shape gitleaks would flag.
  @secrets [
    anthropic: "sk-ant-api03-" <> String.duplicate("Ab3_", 10) <> "AA",
    bearer: "Authorization: Bearer abcDEF123456789xyzTOKEN",
    aws_access_key_id: "AKIAIOSFODNN7EXAMPLE",
    aws_secret_access_key: ~s(aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
    github_pat: "ghp_" <> String.duplicate("a1B2", 9),
    github_fine_grained: "github_pat_" <> String.duplicate("x9Y8_", 16) <> "ab",
    jwt:
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ." <>
        "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
    private_key:
      "-----BEGIN RSA PRIVATE KEY-----\n" <>
        String.duplicate("MIIEowIBAAKCAQEA1x2y3z4", 4) <> "\n-----END RSA PRIVATE KEY-----",
    session_token: "ccst_q8Zr3mXv9LwT2pNs5KdF7hJ4aaaaBBBBccccDDDDeee",
    browser_token: "ccpw_" <> String.duplicate("Zx9-", 8)
  ]

  setup do
    case System.find_executable("docker") do
      nil -> flunk("the :vector tests need docker on PATH")
      _docker -> :ok
    end
  end

  test "vector validate accepts every rendered variant", %{tmp_dir: tmp_dir} do
    for {name, opts} <- @variants do
      dir = Path.join(tmp_dir, Atom.to_string(name))
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "vector.yaml"), LogShipper.config(opts))

      {output, status} =
        vector(dir, ["validate", "--no-environment", "/etc/vector/vector.yaml"])

      assert status == 0, "#{name} did not validate:\n#{output}"
      assert output =~ "Validated"
    end
  end

  test "vector test: every default filter, raw and JSON-escaped, plus fail-closed parsing",
       %{tmp_dir: tmp_dir} do
    config = LogShipper.config(sink: :console, capture_volume: "cclog", proxy_log_volume: "p")
    File.write!(Path.join(tmp_dir, "vector.yaml"), config)

    tests =
      Enum.flat_map(@secrets, fn {name, secret} ->
        [
          redaction_test("#{name} raw", raw_line(secret), "assistant", secret),
          redaction_test("#{name} escaped", escaped_line(secret), "user", secret)
        ]
      end) ++
        [
          redaction_test(
            "unparsed line",
            "not json " <> @secrets[:anthropic],
            "unparsed",
            @secrets[:anthropic]
          ),
          innocent_test(),
          proxy_decision_test(),
          proxy_noise_test()
        ]

    File.write!(Path.join(tmp_dir, "tests.yaml"), YAML.encode([{"tests", tests}]))

    {output, status} =
      vector(tmp_dir, ["test", "/etc/vector/vector.yaml", "/etc/vector/tests.yaml"])

    assert status == 0, "vector test failed:\n#{output}"
    passed = ~r/^test .+ \.\.\. passed$/m |> Regex.scan(output) |> length()
    assert passed == length(tests), output
  end

  # --- fixtures ---

  defp raw_line(secret), do: JSON.encode!(%{"type" => "assistant", "text" => "here: " <> secret})

  # A tool result that is itself JSON: the secret sits one escape level deep.
  defp escaped_line(secret) do
    JSON.encode!(%{"type" => "user", "tool_result" => JSON.encode!(%{"out" => "x " <> secret})})
  end

  defp redaction_test(name, line, type, secret) do
    # The value a filter must remove: the token itself, not the label that
    # announces it.
    needle = secret |> String.split([" ", "\n", "\""], trim: true) |> Enum.max_by(&byte_size/1)

    transcript_test(name, line, """
    assert!(!contains(encode_json(.), #{JSON.encode!(needle)}), "leaked")
    assert_eq!(.type, #{JSON.encode!(type)})
    assert!(is_integer(.offset))
    """)
  end

  defp innocent_test do
    transcript_test("innocent text survives", raw_line("nothing secret here"), """
    assert!(contains(string!(.event.text), "nothing secret here"))
    assert_eq!(.cc.stream, "transcript")
    """)
  end

  defp transcript_test(name, line, conditions) do
    [
      {"name", name},
      {"inputs", [input("transcript_redacted", line)]},
      {"outputs", [output("transcript_redacted", conditions)]}
    ]
  end

  defp proxy_decision_test do
    line =
      JSON.encode!(%{
        "msg" => "CANONICAL-PROXY-DECISION",
        "allow" => false,
        "requested_host" => "wikipedia.org:443",
        "decision_reason" => "default rule policy used"
      })

    [
      {"name", "a proxy decision is shipped"},
      {"inputs", [input("proxy_redacted", line)]},
      {"outputs",
       [
         output("proxy_redacted", """
         assert_eq!(.type, "proxy_decision")
         assert_eq!(.event.allow, false)
         assert_eq!(.cc.stream, "proxy")
         """)
       ]}
    ]
  end

  defp proxy_noise_test do
    [
      {"name", "other proxy output is dropped"},
      {"inputs", [input("proxy_redacted", ~s({"msg":"listening","level":"info"}))]},
      {"no_outputs_from", ["proxy_redacted"]}
    ]
  end

  defp input(transform, line) do
    [
      {"insert_at", transform},
      {"type", "log"},
      {"log_fields", [{"message", line}, {"offset", 0}]}
    ]
  end

  defp output(transform, conditions) do
    [
      {"extract_from", transform},
      {"conditions", [[{"type", "vrl"}, {"source", {:block, conditions}}]]}
    ]
  end

  defp vector(dir, args) do
    System.cmd("docker", ["run", "--rm", "-v", "#{dir}:/etc/vector:ro", @image | args],
      stderr_to_stdout: true
    )
  end
end
