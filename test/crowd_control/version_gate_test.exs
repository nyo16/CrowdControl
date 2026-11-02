defmodule CrowdControl.VersionGateTest do
  use ExUnit.Case, async: true

  alias CrowdControl.VersionGate

  doctest CrowdControl.VersionGate

  describe "the floor matrix (blocker: a half-built session on an old substrate)" do
    test "each feature against the version just below and exactly at its floor" do
      for {feature, component, below, floor} <- [
            {:pod_sidecars, :kubernetes, {1, 28}, {1, 29}},
            {:prestop_sleep, :kubernetes, {1, 29}, {1, 30}},
            {:service_networks, :docker, {25, 0, 4}, {25, 0, 5}},
            {:egress_sidecars, :docker, {25, 0, 4}, {25, 0, 5}}
          ] do
        assert VersionGate.check([feature], %{component => floor}) == :ok

        assert VersionGate.check([feature], %{component => below}) ==
                 {:error, {:version, component, below, floor}}
      end
    end

    test "26.0.0 satisfies the Docker floor, and so does any later minor" do
      assert VersionGate.check([:egress_sidecars], %{docker: {26, 0, 0}}) == :ok
      assert VersionGate.check([:service_networks], %{docker: {25, 1, 0}}) == :ok

      assert VersionGate.check([:service_networks], %{docker: {24, 9, 9}}) ==
               {:error, {:version, :docker, {24, 9, 9}, {25, 0, 5}}}
    end

    test "the highest floor per component wins" do
      assert VersionGate.check([:pod_sidecars, :prestop_sleep], %{kubernetes: {1, 29}}) ==
               {:error, {:version, :kubernetes, {1, 29}, {1, 30}}}
    end

    test "no features needs no versions at all" do
      assert VersionGate.components([]) == []
      assert VersionGate.check([], %{}) == :ok
    end

    test "only the components the features need are asked for" do
      assert VersionGate.components([:pod_sidecars]) == [:kubernetes]
      assert VersionGate.components([:service_networks, :egress_sidecars]) == [:docker]
    end

    test "an unknown version never passes" do
      assert VersionGate.check([:pod_sidecars], %{docker: {27, 0, 0}}) ==
               {:error, {:version, :kubernetes, :unknown, {1, 29}}}
    end

    test "an unknown feature is a programming error, not a silent pass" do
      assert_raise ArgumentError, fn -> VersionGate.check([:teleport], %{}) end
    end
  end
end
