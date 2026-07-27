defmodule CrowdControl.Backend.Shell do
  @moduledoc """
  Shell quoting shared by every backend that crosses an `sh -c` boundary.

  This exists as one module, used by every backend, on purpose. `Backend.Local`
  interpolates env values into a sourced env file; `Backend.Docker` interpolates
  prompts into a `printf ... >> fifo` exec. Both carry attacker-influenced input
  across the same boundary, and a second, subtly different escaper is precisely
  how one of them ends up wrong. `test/crowd_control/security_test.exs` is the
  oracle for this function.
  """

  @doc """
  Wrap `value` in single quotes, rendering every byte inside it inert to `sh`.

  Single-quoting is total in POSIX shell — no escape sequence, variable, or
  substitution is interpreted inside `'...'`. The only byte that needs handling
  is `'` itself, which closes the quote; the standard `'\\''` idiom closes,
  emits a literal quote, and reopens.

      iex> CrowdControl.Backend.Shell.escape("plain")
      "'plain'"

      iex> CrowdControl.Backend.Shell.escape("it's")
      "'it'\\\\''s'"

      iex> CrowdControl.Backend.Shell.escape("$(rm -rf /)")
      "'$(rm -rf /)'"
  """
  @spec escape(term()) :: String.t()
  def escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end
end
