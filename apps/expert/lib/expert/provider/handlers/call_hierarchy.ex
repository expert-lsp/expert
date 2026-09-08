defmodule Expert.Provider.Handlers.CallHierarchy do
  @moduledoc """
  Call Hierarchy requires 3 handlers:

  - Prepare: called with the cursor location where the user requested the Call Hierarchy.
    This is always called first, it resolves the function under the cursor and hands it to
    the client. The client then sends this item back as the payload for the incoming/outgoing
    calls requests.
  - Incoming calls: returns the places that call a function.
  - Outgoing calls: returns the functions called by the selected function.

  Calls outside functions are represented by module or file caller items. These are terminal
  locations: incoming and outgoing requests for them return no calls.

  To form the hierarchy tree in the UI, the client sends a request for incoming/outgoing calls
  one item at a time. In practice, it means the call hierarchy is resolved as the user expands
  each item in their UI.
  """
  @behaviour Expert.Provider.Handler

  import Forge.Document.Line, only: [line: 1]

  alias Expert.Document.Context
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats
  alias Forge.Project
  alias Forge.Search.Indexer.Entry
  alias GenLSP.Enumerations.SymbolKind
  alias GenLSP.Requests
  alias GenLSP.Structures

  @function_kind SymbolKind.function()

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentPrepareCallHierarchy{
          params: %Structures.CallHierarchyPrepareParams{} = params
        },
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context

    with {:ok, _document, %Ast.Analysis{} = analysis} <-
           Document.Store.fetch(document.uri, :analysis),
         {:ok, {:call, module, function, arity}, _range} <-
           Expert.EngineApi.resolve_entity(project, analysis, params.position) do
      mfa = Formats.mfa(module, function, arity)

      case Expert.Search.Store.exact(project, mfa, subtype: :definition) do
        {:ok, [definition | _]} -> {:ok, [build_call_item(definition, project)]}
        _ -> {:ok, []}
      end
    else
      _ ->
        {:ok, []}
    end
  end

  def handle(
        %request{params: %{item: %{kind: kind}}},
        %Context{}
      )
      when request in [Requests.CallHierarchyIncomingCalls, Requests.CallHierarchyOutgoingCalls] and
             kind != @function_kind do
    {:ok, []}
  end

  def handle(
        %Requests.CallHierarchyIncomingCalls{
          params: %Structures.CallHierarchyIncomingCallsParams{} = params
        },
        %Context{} = context
      ) do
    %Context{project: project} = context
    item = params.item

    with {:ok, references} <-
           Expert.Search.Store.exact(project, item.name,
             type: {:function, :usage},
             subtype: :reference
           ),
         references_by_caller =
           references
           |> Enum.reject(&is_nil(&1.caller))
           |> Enum.group_by(&{&1.path, &1.caller}),
         subjects =
           for({{path, caller}, _references} <- references_by_caller, caller != path, do: caller),
         {:ok, definitions} <-
           Expert.Search.Store.exact_many(project, subjects, subtype: :definition) do
      definitions_by_caller = Enum.group_by(definitions, &{&1.path, format_subject(&1.subject)})

      incoming_calls =
        for {key, references} <- references_by_caller,
            {:ok, caller} <- [caller_item(key, definitions_by_caller, project)] do
          %Structures.CallHierarchyIncomingCall{
            from: caller,
            from_ranges: for(reference <- references, do: reference.range)
          }
        end

      {:ok, incoming_calls}
    else
      {:error, _} = error ->
        error

      _ ->
        {:ok, []}
    end
  end

  def handle(
        %Requests.CallHierarchyOutgoingCalls{
          params: %Structures.CallHierarchyOutgoingCallsParams{} = params
        },
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context
    item = params.item

    with {:ok, definitions} <- Expert.Search.Store.exact(project, item.name, subtype: :definition),
         %Entry{} = definition <- Enum.find(definitions, &(&1.path == document.path)),
         caller = caller_subject(definition, document),
         {:ok, references} <-
           Expert.Search.Store.by_caller(project, caller, document.path,
             type: {:function, :usage},
             subtype: :reference
           ),
         references_by_callee = Enum.group_by(references, & &1.subject),
         subjects = Map.keys(references_by_callee),
         {:ok, definitions} <-
           Expert.Search.Store.exact_many(project, subjects, subtype: :definition) do
      definitions_by_callee = Enum.group_by(definitions, &{&1.path, &1.subject})

      # We only use the first definition clause for the item range
      outgoing_calls =
        Enum.map(definitions_by_callee, fn {{_path, subject}, [clause | _]} ->
          references = Map.fetch!(references_by_callee, subject)

          %Structures.CallHierarchyOutgoingCall{
            to: build_call_item(clause, project),
            from_ranges: for(reference <- references, uniq: true, do: reference.range)
          }
        end)

      {:ok, outgoing_calls}
    else
      {:error, _} = error ->
        error

      _ ->
        {:ok, []}
    end
  end

  defp caller_item({path, caller}, _definitions, project) when path == caller do
    uri = Document.Path.to_uri(path)

    result =
      case Document.Store.fetch(uri) do
        {:ok, document} -> {:ok, document}
        {:error, :not_open} -> Document.Store.open_temporary(uri)
      end

    with {:ok, document} <- result do
      {:ok, build_call_item(document, project)}
    end
  end

  defp caller_item(key, definitions, project) do
    with {:ok, [definition | _]} <- Map.fetch(definitions, key) do
      {:ok, build_call_item(definition, project)}
    end
  end

  # Functions with defaults produce with an arity lower than the total number of arguments
  # For example this:
  #
  #     def foo(a \\ []), do: Enum.reverse(a)
  #
  # Produces foo/1 and foo/0. A call to `foo()` needs to point to this function, but the
  # index contains only the entry for `foo/1`. This helper resolves that discrepancy.
  defp caller_subject(%Entry{} = entry, %Document{} = document) do
    case Ast.zipper_at(document, entry.range.start) do
      {:ok, %{node: node}} -> subject_for_head(entry.subject, node)
      _ -> entry.subject
    end
  end

  defp subject_for_head(subject, {kind, _, [head | _]})
       when kind in [:def, :defp, :defmacro, :defmacrop, :defdelegate, :when] do
    subject_for_head(subject, head)
  end

  defp subject_for_head(subject, {name, _, args}) when is_atom(name) and is_list(args) do
    {arity_text, name_parts} = subject |> String.split("/") |> List.pop_at(-1)
    prefix = Enum.join(name_parts, "/") <> "/"
    arity = length(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))

    with {requested_arity, ""} <- Integer.parse(arity_text),
         true <- requested_arity in (arity - defaults)..arity do
      prefix <> Integer.to_string(arity)
    else
      _ -> subject
    end
  end

  defp subject_for_head(subject, _head), do: subject

  defp build_call_item(%Entry{} = entry, %Project{} = project) do
    %Structures.CallHierarchyItem{
      name: format_subject(entry.subject),
      kind: if(module_definition?(entry), do: SymbolKind.module(), else: SymbolKind.function()),
      uri: Document.Path.to_uri(entry.path),
      # Use the range for the entire entry, or its range if it has no body
      # (defdelegates, function header with defaults, etc)
      range: entry.block_range || entry.range,
      selection_range: entry.range,
      data: %{"project_root_uri" => project.root_uri}
    }
  end

  defp build_call_item(%Document{} = document, %Project{} = project) do
    start = Position.new(document, 1, 1)
    last_line = Document.size(document)

    # LSP range encloses the file; selection_range below is the navigation target.
    finish =
      case Document.fetch_line_at(document, last_line) do
        {:ok, line(text: text, ending: "")} ->
          Position.new(document, last_line, String.length(text) + 1)

        {:ok, _line_with_ending} ->
          Position.new(document, last_line + 1, 1)

        :error ->
          start
      end

    %Structures.CallHierarchyItem{
      name: Path.basename(document.path),
      kind: SymbolKind.file(),
      uri: document.uri,
      range: Range.new(start, finish),
      selection_range: Range.new(start, start),
      data: %{"project_root_uri" => project.root_uri}
    }
  end

  defp format_subject(subject) when is_binary(subject), do: subject
  defp format_subject(subject) when is_atom(subject), do: Formats.module(subject)

  defp module_definition?(%Entry{type: :module}), do: true
  defp module_definition?(%Entry{type: {:protocol, _}}), do: true
  defp module_definition?(_entry), do: false
end
