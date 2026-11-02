defmodule CrowdControl.StoreScrubTest do
  # Store.scrub_opts/1 is pure, so unlike store_test.exs this runs async.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrowdControl.{Service, Store}

  doctest Store, only: [scrub_opts: 1, scrub_services: 1]

  # Secrets carry a marker no plain value can: alphanumeric strings have no "-".
  @marker "SECRET-"
  @plain_keys [:timeout, :image, :model, :cwd, :max_turns, :mock]
  @nesting [:backend, :provider]

  defp secret, do: map(string(:alphanumeric, min_length: 4), &(@marker <> &1))

  defp plain_value,
    do: one_of([integer(), boolean(), string(:alphanumeric), list_of(atom(:alphanumeric))])

  defp plain_entry, do: tuple({member_of(@plain_keys), plain_value()})

  defp secret_entry do
    tuple({member_of(Store.secret_keys()), one_of([secret(), map_of(secret(), secret())])})
  end

  defp service do
    fixed_map(%{
      name: string(:alphanumeric, min_length: 1),
      image: constant("img:1"),
      env: map_of(string(:alphanumeric, min_length: 1), secret(), max_length: 3),
      files:
        list_of(fixed_map(%{path: constant("/etc/x.conf"), content: secret()}), max_length: 2)
    })
  end

  # A keyword level: plain and secret entries interleaved, a :services list,
  # and `backend:`/`provider:` tuples holding another level.
  defp opts(0), do: level(constant([]))

  defp opts(depth) do
    nested =
      list_of(
        tuple({member_of(@nesting), tuple({member_of([Mod.A, Mod.B]), opts(depth - 1)})}),
        max_length: 2
      )

    level(nested)
  end

  defp level(nested) do
    gen all(
          entries <- list_of(one_of([plain_entry(), secret_entry()]), max_length: 6),
          services <- list_of(service(), max_length: 3),
          nested <- nested
        ) do
      entries ++ [services: services] ++ nested
    end
  end

  defp contains_secret?(term),
    do: :binary.match(:erlang.term_to_binary(term), @marker) != :nomatch

  # Every entry that is not a secret survives, in order; services lose only
  # :env and :files; nested tuples are scrubbed by the same rules.
  defp assert_kept(original, scrubbed) do
    kept = Enum.reject(original, fn {key, _} -> key in Store.secret_keys() end)
    assert length(kept) == length(scrubbed)

    Enum.zip_with(kept, scrubbed, fn
      {:services, specs}, {:services, out} ->
        assert out == Enum.map(specs, &Map.drop(&1, [:env, :files]))

      {key, {module, config}}, {key, {module, out}} when key in @nesting ->
        assert_kept(config, out)

      entry, out ->
        assert entry == out
    end)
  end

  property "no secret survives scrub_opts/1, and nothing else is lost" do
    check all(opts <- opts(2), max_runs: 100) do
      scrubbed = Store.scrub_opts(opts)

      refute contains_secret?(scrubbed)
      assert_kept(opts, scrubbed)
      assert Store.scrub_opts(scrubbed) == scrubbed
    end
  end

  describe "scrub_opts/1" do
    test "recurses into backend: and a nested provider:" do
      opts = [
        api_key: "k",
        timeout: 5_000,
        backend:
          {Mod.Backend,
           session_token: "ccst_x",
           image: "sbx:dev",
           services: [%{name: "b", env: %{"T" => "s"}, files: [%{path: "/f", content: "c"}]}],
           provider: {Mod.Provider, api_key: "p", gce_config: %{token: "t"}, zone: "eu"}}
      ]

      assert Store.scrub_opts(opts) == [
               timeout: 5_000,
               backend:
                 {Mod.Backend,
                  image: "sbx:dev", services: [%{name: "b"}], provider: {Mod.Provider, zone: "eu"}}
             ]
    end

    test "leaves a module-only backend and non-keyword values alone" do
      assert Store.scrub_opts(backend: Mod.Backend, timeout: 1) == [
               backend: Mod.Backend,
               timeout: 1
             ]

      assert Store.scrub_opts(nil) == nil
    end
  end

  describe "scrub_services/1" do
    test "keeps a %Service{} a struct, with env and files emptied" do
      service = %Service{name: "db", image: "pg", env: %{"P" => "s"}, files: [%{content: "c"}]}

      assert [%Service{name: "db", image: "pg", env: %{}, files: []}] =
               Store.scrub_services([service])
    end

    test "keeps non-map entries unchanged" do
      assert Store.scrub_services([:x, %{name: "a", env: %{"K" => "v"}}]) == [:x, %{name: "a"}]
    end
  end
end
