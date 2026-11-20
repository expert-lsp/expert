defmodule Engine.Build.Isolation do
  @moduledoc """
  Runs functions in an isolated, monitored process
  """

  alias Engine.Build.Error

  @doc "Captures diagnostics and failures while a saved project loads or builds."
  def with_diagnostics(path, fun) do
    case invoke(fn -> Code.with_diagnostics(fn -> evaluate(fun) end) end) do
      {:ok, {result, raw_diagnostics}} ->
        diagnostics =
          path |> Error.diagnostics_from_mix(raw_diagnostics) |> Error.refine_diagnostics()

        case result do
          {:ok, value} -> {:ok, value, diagnostics}
          {:error, failure} -> failed(path, failure, diagnostics)
        end

      {:error, {exception, stack}} when is_exception(exception) and is_list(stack) ->
        failed(path, {:error, exception, stack}, [])

      {:error, reason} ->
        failed(path, {:exit, reason, []}, [])
    end
  end

  defp failed(path, failure, diagnostics) do
    if Enum.any?(diagnostics, &(&1.severity == :error)) do
      {:error, diagnostics}
    else
      {:error, diagnostics ++ [Error.from_failure(path, failure)]}
    end
  end

  defp evaluate(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
  end

  @spec invoke((-> term())) :: {:ok, term()} | {:error, term()}
  def invoke(function) when is_function(function, 0) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(me, {:result, function.()})
      end)

    receive do
      {:result, result} ->
        # clean up the DOWN message from the above process in the mailbox.
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, {reason, stacktrace}} when is_list(stacktrace) ->
        # normalize the error into an exception struct so callers can handle it.

        {:error, {Exception.normalize(:error, reason, stacktrace), stacktrace}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    end
  end
end
