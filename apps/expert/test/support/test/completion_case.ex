defmodule Expert.Test.Expert.CompletionCase do
  use ExUnit.CaseTemplate

  import Forge.EngineApi.Messages
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures

  alias Expert.CodeIntelligence.Completion
  alias Expert.EngineApi
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Project
  alias Forge.Test.CodeSigil
  alias GenLSP.Enumerations.CompletionTriggerKind
  alias GenLSP.Structures.CompletionContext
  alias GenLSP.Structures.CompletionItem
  alias GenLSP.Structures.CompletionList

  setup_all do
    project = project()

    start_supervised!({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})
    start_supervised!(Expert.EngineBuilds)
    start_supervised!(Expert.ActiveProjects)
    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    start_supervised!({Expert.Project.Supervisor, project})

    EngineApi.register_listener(project, self(), [
      project_compiled(),
      project_index_ready()
    ])

    EngineApi.schedule_compile(project, true)
    assert_receive project_compiled(), 5000
    assert_receive project_index_ready(), 5000
    {:ok, project: project}
  end

  using do
    quote do
      import unquote(__MODULE__)
      import unquote(CodeSigil), only: [sigil_q: 2]
    end
  end

  def apply_completion(%CompletionItem{text_edit: %Document.Changes{} = changes}) do
    edits = List.wrap(changes.edits)
    {:ok, edited_document} = Document.apply_content_changes(changes.document, 1, edits)
    Document.to_string(edited_document)
  end

  def complete(project, text, opts \\ []) do
    return_as_list? = Keyword.get(opts, :as_list, true)
    trigger_character = Keyword.get(opts, :trigger_character)
    root_path = Project.root_path(project)

    file_path =
      case Keyword.fetch(opts, :path) do
        {:ok, path} ->
          if String.starts_with?(path, "/") do
            # On Windows, absolute paths start with the drive name, but we write
            # tests mostly assuming Linux/macos. This handles that discrepancy.
            if Forge.OS.windows?(), do: Path.expand(path), else: path
          else
            Path.join(root_path, path)
          end

        :error ->
          Path.join([root_path, "lib", "file.ex"])
      end

    {position, document} = pop_cursor(text, document: file_path)

    context =
      if is_binary(trigger_character) do
        %CompletionContext{
          trigger_kind: CompletionTriggerKind.trigger_character(),
          trigger_character: trigger_character
        }
      else
        %CompletionContext{trigger_kind: CompletionTriggerKind.invoked()}
      end

    analysis = Ast.analyze(document)
    result = Completion.complete(project, analysis, position, context)

    if return_as_list? do
      completion_items(result)
    else
      result
    end
  end

  def fetch_completion(completions, label_prefix) when is_binary(label_prefix) do
    matcher = &String.starts_with?(&1.label, label_prefix)

    completions
    |> completion_items()
    |> Enum.filter(matcher)
    |> case do
      [] -> {:error, :not_found}
      [found] -> {:ok, found}
      found when is_list(found) -> {:ok, found}
    end
  end

  def fetch_completion(completions, kind) when is_integer(kind) do
    matcher = fn completion ->
      Map.get(completion, :kind) == kind
    end

    completions
    |> completion_items()
    |> Enum.filter(matcher)
    |> case do
      [] -> {:error, :not_found}
      [found] -> {:ok, found}
      found when is_list(found) -> {:ok, found}
    end
  end

  def fetch_completion(completions, opts) when is_list(opts) do
    matcher = fn completion ->
      Enum.reduce_while(opts, false, fn {key, value}, _ ->
        if Map.get(completion, key) == value do
          {:cont, true}
        else
          {:halt, false}
        end
      end)
    end

    completions
    |> completion_items()
    |> Enum.filter(matcher)
    |> case do
      [] -> {:error, :not_found}
      [found] -> {:ok, found}
      found when is_list(found) -> {:ok, found}
    end
  end

  defp completion_items(%CompletionList{items: items}), do: items
  defp completion_items(items) when is_list(items), do: items
end
