defmodule CrowdControl.ResultTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrowdControl.Agent.Omp
  alias CrowdControl.{Error, Result}

  # Claude Code result frames. The success and aborted_tools shapes are the
  # ones verify-control recorded from CLI 2.1.292; the API-error texts follow
  # the CLI's "API Error: <status> <body>" format.
  @success %{
    "type" => "result",
    "subtype" => "success",
    "is_error" => false,
    "stop_reason" => "end_turn",
    "terminal_reason" => "completed",
    "num_turns" => 2,
    "permission_denials" => [],
    "result" => "tool said: \"hi-from-host\"",
    "total_cost_usd" => 0.0123,
    "session_id" => "sess-1"
  }

  defp result(map), do: {:result, map["subtype"], map}

  defp claude_error(subtype, fields) do
    Map.merge(
      %{
        "type" => "result",
        "subtype" => subtype,
        "is_error" => true,
        "session_id" => "sess-1",
        "num_turns" => 3,
        "total_cost_usd" => 0.5
      },
      fields
    )
  end

  describe "classify/1, Claude Code results" do
    test "success is {:ok, map}, unchanged" do
      assert Result.classify(result(@success)) == {:ok, @success}
    end

    test "error_max_turns is :max_turns_exceeded" do
      assert {:error, %Error{} = error} =
               Result.classify(result(claude_error("error_max_turns", %{})))

      assert %Error{
               kind: :max_turns_exceeded,
               reason: %{num_turns: 3},
               subtype: "error_max_turns",
               session_id: "sess-1"
             } = error

      assert Exception.message(error) =~ "after 3 turns"
    end

    test "error_max_budget_usd is :max_budget_exceeded with cap, cost and turns" do
      map =
        claude_error("error_max_budget_usd", %{"errors" => ["Reached maximum budget ($0.50)"]})

      assert {:error,
              %Error{
                kind: :max_budget_exceeded,
                reason: %{cap: 0.5, cost_usd: 0.5, num_turns: 3}
              }} = Result.classify(result(map))
    end

    test "a max_budget_usd field is preferred over the text" do
      map = claude_error("error_max_budget_usd", %{"max_budget_usd" => 2, "errors" => ["$9"]})

      assert {:error, %Error{reason: %{cap: 2}}} = Result.classify(result(map))
    end

    test "a budget error without a cap anywhere has cap nil" do
      map = claude_error("error_max_budget_usd", %{})
      assert {:error, %Error{reason: %{cap: nil}}} = Result.classify(result(map))
    end

    test "error_during_execution with aborted_tools is :aborted" do
      map =
        claude_error("error_during_execution", %{
          "stop_reason" => "tool_use",
          "terminal_reason" => "aborted_tools",
          "errors" => [
            "[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"
          ]
        })

      assert {:error, %Error{kind: :aborted, reason: reason}} = Result.classify(result(map))
      assert reason =~ "ede_diagnostic"
    end

    test "error_during_execution otherwise is :execution_error" do
      map = claude_error("error_during_execution", %{"errors" => ["tool crashed"]})

      assert {:error, %Error{kind: :execution_error, reason: "tool crashed"}} =
               Result.classify(result(map))
    end

    for {status, category, body} <- [
          {429, :rate_limit,
           ~s({"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}})},
          {529, :overloaded,
           ~s({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}})},
          {500, :server_error,
           ~s({"type":"error","error":{"type":"api_error","message":"Internal server error"}})},
          {503, :server_error, "Service Unavailable"},
          {400, :other,
           ~s({"type":"error","error":{"type":"invalid_request_error","message":"bad"}})}
        ] do
      test "an API Error #{status} is :api_error #{category}" do
        map =
          claude_error("success", %{
            "result" => "API Error: #{unquote(status)} #{unquote(body)}",
            "terminal_reason" => "api_error"
          })

        assert {:error,
                %Error{
                  kind: :api_error,
                  reason: %{category: unquote(category), status: unquote(status)},
                  subtype: "success"
                }} = Result.classify(result(map))
      end
    end

    test "an API error status in a JSON body is found" do
      map = claude_error("success", %{"result" => ~s(request failed {"status": 529})})

      assert {:error, %Error{kind: :api_error, reason: %{category: :overloaded, status: 529}}} =
               Result.classify(result(map))
    end

    test "an API error without a status is categorised from the text" do
      map = claude_error("success", %{"result" => "API Error: rate_limit_error"})

      assert {:error, %Error{kind: :api_error, reason: %{category: :rate_limit, status: nil}}} =
               Result.classify(result(map))
    end

    test "a connection failure is :api_error :connection" do
      map =
        claude_error("success", %{
          "result" => "API Error: Connection error.",
          "terminal_reason" => "api_error"
        })

      assert {:error, %Error{kind: :api_error, reason: %{category: :connection, status: nil}}} =
               Result.classify(result(map))
    end

    test "an API failure during execution is :api_error, not :execution_error" do
      map = claude_error("error_during_execution", %{"errors" => ["API Error: 529 Overloaded"]})

      assert {:error, %Error{kind: :api_error, reason: %{category: :overloaded}}} =
               Result.classify(result(map))
    end

    test "an invalid key is :auth" do
      map = claude_error("success", %{"result" => "Invalid API key · Please run /login"})

      assert {:error, %Error{kind: :auth, reason: "Invalid API key · Please run /login"}} =
               Result.classify(result(map))
    end

    test "a 401 is :auth" do
      map =
        claude_error("success", %{
          "result" => ~s(API Error: 401 {"type":"error","error":{"type":"authentication_error"}})
        })

      assert {:error, %Error{kind: :auth}} = Result.classify(result(map))
    end

    test "an error success with no recognisable cause is :unknown" do
      map = claude_error("success", %{"result" => "something odd"})

      assert {:error, %Error{kind: :unknown, reason: "something odd", subtype: "success"}} =
               Result.classify(result(map))
    end

    # 2.1.292 result frames: `terminal_reason: "api_error"` with the status in
    # `api_error_status` and the API's error in `api_error`.
    for {status, category} <- [
          {429, :rate_limit},
          {529, :overloaded},
          {500, :server_error},
          {400, :other}
        ] do
      test "api_error_status #{status} is :api_error #{category}, whatever the text says" do
        map =
          claude_error("success", %{
            "result" => "API Error: something went wrong",
            "terminal_reason" => "api_error",
            "api_error_status" => unquote(status),
            "api_error" => "upstream said no"
          })

        assert {:error,
                %Error{
                  kind: :api_error,
                  reason: %{
                    category: unquote(category),
                    status: unquote(status),
                    api_error: "upstream said no"
                  }
                }} = Result.classify(result(map))
      end
    end

    test "the status field wins over a status in the text" do
      map =
        claude_error("success", %{
          "result" => "API Error: 500 Internal server error",
          "terminal_reason" => "api_error",
          "api_error_status" => 529
        })

      assert {:error, %Error{reason: %{category: :overloaded, status: 529}}} =
               Result.classify(result(map))
    end

    test "api_error_status 401 is :auth even when the text does not say so" do
      map =
        claude_error("success", %{
          "result" => "API Error",
          "terminal_reason" => "api_error",
          "api_error_status" => 401
        })

      assert {:error, %Error{kind: :auth, reason: "API Error"}} = Result.classify(result(map))
    end

    test "an api_error without api_error_status is :connection" do
      map =
        claude_error("success", %{
          "result" => "API Error: Connection error.",
          "terminal_reason" => "api_error"
        })

      assert {:error,
              %Error{
                kind: :api_error,
                reason: %{category: :connection, status: nil, api_error: nil}
              }} =
               Result.classify(result(map))
    end

    # Recorded from claude 2.1.292 against a closed port: the status and error
    # fields are present but null.
    test "a recorded 2.1.292 connection failure is :connection" do
      map =
        claude_error("success", %{
          "result" =>
            "API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)",
          "terminal_reason" => "api_error",
          "api_error_status" => nil,
          "api_error" => nil,
          "num_turns" => 1,
          "total_cost_usd" => 0
        })

      assert {:error, %Error{kind: :api_error, reason: %{category: :connection, status: nil}}} =
               Result.classify(result(map))
    end

    test "api_error_status is ignored unless terminal_reason is api_error" do
      map =
        claude_error("error_during_execution", %{
          "errors" => ["tool crashed"],
          "api_error_status" => 529
        })

      assert {:error, %Error{kind: :execution_error}} = Result.classify(result(map))
    end

    test "error_max_structured_output_retries is :structured_output_failed" do
      text = "Failed to provide valid structured output after maximum retries"
      map = claude_error("error_max_structured_output_retries", %{"errors" => [text]})

      assert {:error, %Error{kind: :structured_output_failed, reason: ^text} = error} =
               Result.classify(result(map))

      assert Exception.message(error) =~ "maximum retries"
    end
  end

  describe "classify/1, omp results" do
    test "a rejected prompt is :prompt_failed" do
      line =
        ~s({"type":"response","command":"prompt","success":false,"error":"busy","code":"E_BUSY"})

      assert {:result, "error_prompt_failed", _} = omp_result = Omp.decode_line(line)

      assert {:error,
              %Error{
                kind: :prompt_failed,
                reason: %{message: "busy", code: "E_BUSY"},
                subtype: "error_prompt_failed"
              } = error} = Result.classify(omp_result)

      assert Exception.message(error) =~ "busy"
    end

    test "agent_end is {:ok, map}" do
      line = ~s({"type":"agent_end","messages":[]})
      assert {:result, "success", map} = omp_result = Omp.decode_line(line)
      assert Result.classify(omp_result) == {:ok, map}
    end
  end

  describe "classify/1, unknown input" do
    test "an unknown subtype is :unknown and keeps the binary" do
      map = claude_error("error_from_a_future_cli", %{})

      assert {:error, %Error{kind: :unknown, subtype: "error_from_a_future_cli"}} =
               Result.classify(result(map))
    end

    test "a non-binary subtype is :unknown" do
      assert {:error, %Error{kind: :unknown, subtype: nil}} =
               Result.classify({:result, 42, %{}})
    end

    test "a non-map payload is classified as an empty map" do
      assert {:error, %Error{kind: :max_turns_exceeded, raw: %{}}} =
               Result.classify({:result, "error_max_turns", "not a map"})
    end

    test "anything that is not a result tuple is :unknown" do
      assert {:error, %Error{kind: :unknown}} = Result.classify({:exit, 0})
    end
  end

  describe "accessors" do
    test "read a result map, a result tuple and an Error alike" do
      {:error, error} = Result.classify(result(claude_error("error_max_turns", %{})))

      for source <- [@success, result(@success)] do
        assert Result.cost_usd(source) == 0.0123
        assert Result.session_id(source) == "sess-1"
        assert Result.num_turns(source) == 2
        assert Result.permission_denials(source) == []
      end

      assert Result.cost_usd(error) == 0.5
      assert Result.num_turns(error) == 3
    end

    test "absent or mistyped fields give nil, or [] for denials" do
      map = %{"total_cost_usd" => "1", "session_id" => 7, "num_turns" => -1}

      assert Result.cost_usd(map) == nil
      assert Result.session_id(map) == nil
      assert Result.num_turns(map) == nil
      assert Result.permission_denials(map) == []
    end

    test "permission_denials returns the list" do
      denial = %{"tool_name" => "Bash", "tool_use_id" => "t1", "tool_input" => %{}}
      assert Result.permission_denials(%{"permission_denials" => [denial]}) == [denial]
    end

    test "structured_output reads a map or a list, anything else is nil" do
      assert Result.structured_output(%{"structured_output" => %{"a" => 1}}) == %{"a" => 1}
      assert Result.structured_output(result(%{"structured_output" => [1, 2]})) == [1, 2]
      assert Result.structured_output(%{"structured_output" => "text"}) == nil
      assert Result.structured_output(%{"structured_output" => nil}) == nil
      assert Result.structured_output(@success) == nil
    end

    test "usage normalises the snake_case counts, missing ones are 0" do
      usage = %{
        "input_tokens" => 12,
        "output_tokens" => 34,
        "cache_creation_input_tokens" => 5,
        "cache_read_input_tokens" => 600,
        "server_tool_use" => %{"web_search_requests" => 0}
      }

      assert Result.usage(result(Map.put(@success, "usage", usage))) ==
               %{input: 12, output: 34, cache_creation: 5, cache_read: 600}

      assert Result.usage(%{"usage" => %{"input_tokens" => 3, "output_tokens" => "x"}}) ==
               %{input: 3, output: 0, cache_creation: 0, cache_read: 0}

      assert Result.usage(@success) == nil
      assert Result.usage(%{"usage" => "none"}) == nil
    end

    test "usage reads omp's keys, and a map with no known count is nil" do
      omp = %{"input" => 1, "output" => 2, "cacheRead" => 9, "totalTokens" => 3, "cost" => %{}}

      assert Result.usage(%{"usage" => omp}) ==
               %{input: 1, output: 2, cache_creation: 0, cache_read: 9}

      assert Result.usage(%{"usage" => %{"cost" => %{"total" => 0.25}}}) == nil
    end
  end

  describe "decode_structured/1" do
    test "a successful turn returns its structured_output" do
      map = Map.put(@success, "structured_output", %{"answer" => 42})
      assert Result.decode_structured(result(map)) == {:ok, %{"answer" => 42}}
    end

    test "a successful turn without structured_output is :no_structured_output" do
      for map <- [@success, Map.put(@success, "structured_output", nil)] do
        assert {:error, %Error{kind: :no_structured_output, subtype: "success"} = error} =
                 Result.decode_structured(result(map))

        assert Exception.message(error) =~ "no structured_output"
      end
    end

    test "an error result keeps its own kind, even with output" do
      map =
        claude_error("error_max_structured_output_retries", %{"structured_output" => %{"a" => 1}})

      assert {:error, %Error{kind: :structured_output_failed}} =
               Result.decode_structured(result(map))

      assert {:error, %Error{kind: :unknown}} = Result.decode_structured(:not_a_result)
    end
  end

  describe "properties" do
    @subtypes [
      "success",
      "error_max_turns",
      "error_max_budget_usd",
      "error_during_execution",
      "error_prompt_failed",
      "error_max_structured_output_retries"
    ]

    @keys [
      "is_error",
      "result",
      "errors",
      "terminal_reason",
      "total_cost_usd",
      "num_turns",
      "session_id",
      "permission_denials",
      "max_budget_usd",
      "error_code",
      "api_error_status",
      "api_error",
      "structured_output",
      "usage"
    ]

    defp value do
      StreamData.one_of([
        StreamData.constant(nil),
        StreamData.boolean(),
        StreamData.integer(),
        StreamData.float(),
        StreamData.binary(),
        StreamData.string(:printable),
        StreamData.member_of(["api_error", "aborted_tools", "API Error: 529", "$1.5"]),
        StreamData.list_of(StreamData.one_of([StreamData.binary(), StreamData.integer()]),
          max_length: 3
        ),
        StreamData.map_of(StreamData.string(:alphanumeric), StreamData.integer(), max_length: 2)
      ])
    end

    defp result_map do
      StreamData.optional_map(Map.new(@keys, &{&1, value()}))
    end

    defp subtype do
      StreamData.one_of([StreamData.member_of(@subtypes), StreamData.binary(), value()])
    end

    property "no input map raises, and every error has a known kind and a message" do
      check all(subtype <- subtype(), map <- result_map()) do
        message = {:result, subtype, map}

        case Result.classify(message) do
          {:ok, ^map} ->
            :ok

          {:error, %Error{kind: kind} = error} ->
            assert kind in Error.kinds()
            assert is_binary(Exception.message(error))
        end

        Result.cost_usd(message)
        Result.session_id(message)
        Result.num_turns(message)
        assert is_list(Result.permission_denials(message))
        Result.structured_output(message)
        Result.usage(message)
        assert {_, _} = Result.decode_structured(message)
      end
    end

    property "arbitrary terms never raise" do
      check all(term <- StreamData.term()) do
        assert {_, _} = Result.classify(term)
        assert {_, _} = Result.classify({:result, term, term})
      end
    end
  end
end
