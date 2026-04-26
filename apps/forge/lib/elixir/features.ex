defmodule Elixir.Features do
  alias Forge.VM.Versions

  def with_diagnostics? do
    function_exported?(Code, :with_diagnostics, 1)
  end

  def compile_keeps_current_directory? do
    Versions.current_elixir_matches?(">= 1.15.0")
  end

  def after_verify? do
    Versions.current_elixir_matches?(">= 1.14.0")
  end

  def details_in_context? do
    Versions.current_elixir_matches?(">= 1.16.0")
  end

  def span_in_diagnostic? do
    Versions.current_elixir_matches?(">= 1.16.0")
  end

  def contains_set_theoretic_types? do
    Versions.current_elixir_matches?(">= 1.17.0")
  end

  def lazy_loading? do
    Versions.current_elixir_matches?(">= 1.19.0")
  end

  def macro_env_functions_avaialable? do
    Versions.current_elixir_matches?(">= 1.17.0")
  end

  @doc """
  Whether the `:compressed` ETS table option can be safely used.

  A bug in Erlang/OTP 27.0.0 and 27.0.1 can cause a segfault when
  traversing the entire table with something like `:ets.foldl/3` if the
  `:compressed` table option is used. The issue was fixed in Erlang 27.1

  Relevant issue: https://github.com/erlang/otp/issues/8682
  """
  def can_use_compressed_ets_table? do
    %{erlang: erlang_version} = Versions.to_versions(Versions.current())

    Version.match?(erlang_version, "< 27.0.0 or >= 27.1.0")
  end
end
