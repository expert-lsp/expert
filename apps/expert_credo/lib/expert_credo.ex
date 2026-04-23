defmodule ExpertCredo do
  @moduledoc false

  use Forge.Plugin.V1.Diagnostic, name: :expert_credo

  alias Forge.Document
  alias Forge.Plugin.V1.Diagnostic
  alias Forge.Project

  require Logger

  @doc false
  def init do
    with {:ok, _} <- Application.ensure_all_started(:credo) do
      :ok
    end
  end

  @doc false
  def document do
    %Document{}
  end

  @doc false
  def diagnose(%Document{} = doc) do
    doc_contents = Document.to_string(doc)

    execution_args = [
      "--mute-exit-status",
      "--read-from-stdin",
      Document.Path.absolute_from_uri(doc.uri)
    ]

    execution = Credo.Execution.build(execution_args)

    with_stdin(
      doc_contents,
      fn ->
        Credo.CLI.Output.Shell.suppress_output(fn ->
          Credo.Execution.run(execution)
        end)
      end
    )

    diagnostics =
      execution
      |> Credo.Execution.get_issues()
      |> Enum.map(&to_diagnostic/1)

    {:ok, diagnostics}
  end

  @doc false
  def diagnose(%Project{}) do
    results =
      Credo.Execution.build()
      |> Credo.Execution.run()
      |> Credo.Execution.get_issues()
      |> Enum.map(&to_diagnostic/1)

    {:ok, results}
  end

  @doc false
  def with_stdin(stdin_contents, function) when is_function(function, 0) do
    {:ok, stdio} = StringIO.open(stdin_contents)
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.group_leader(self(), stdio)
        result = function.()
        send(caller, {:result, result})
      end)

    receive do
      {:result, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      30_000 ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end

  defp to_diagnostic(%Credo.Issue{} = issue) do
    file_path = Document.Path.ensure_uri(issue.filename)

    Diagnostic.Result.new(
      file_path,
      location(issue),
      issue.message,
      priority_to_severity(issue),
      "Credo"
    )
  end

  defp priority_to_severity(%Credo.Issue{priority: priority}) do
    case Credo.Priority.to_atom(priority) do
      :higher -> :error
      :high -> :warning
      :normal -> :information
      _ -> :hint
    end
  end

  defp location(%Credo.Issue{} = issue) do
    case {issue.line_no, issue.column} do
      {line, nil} -> line
      location -> location
    end
  end
end
