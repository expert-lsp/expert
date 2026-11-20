defmodule Expert.Project.Diagnostics.State do
  alias Forge.Diagnostic
  alias Forge.Document
  alias Forge.Project

  require Logger

  defmodule Entry do
    defstruct build_number: 0, diagnostics: []

    def new(build_number) when is_integer(build_number) do
      %__MODULE__{build_number: build_number}
    end

    def new(build_number, diagnostic) do
      %__MODULE__{build_number: build_number, diagnostics: MapSet.new([diagnostic])}
    end

    def add(%__MODULE__{} = entry, build_number, diagnostic) do
      cond do
        build_number < entry.build_number ->
          entry

        build_number > entry.build_number ->
          new(build_number, diagnostic)

        true ->
          %__MODULE__{entry | diagnostics: MapSet.put(entry.diagnostics, diagnostic)}
      end
    end

    def diagnostics(%__MODULE__{} = entry) do
      Enum.to_list(entry.diagnostics)
    end
  end

  defstruct project: nil, entries_by_uri: %{}, file_entries_by_uri: %{}

  def new(%Project{} = project) do
    %__MODULE__{project: project}
  end

  def get(%__MODULE__{} = state, source_uri) do
    project_diagnostics =
      state.entries_by_uri
      |> Map.get(source_uri, Entry.new(0))
      |> Entry.diagnostics()

    file_diagnostics =
      state.file_entries_by_uri
      |> Map.get(source_uri, Entry.new(0))
      |> Entry.diagnostics()

    project_diagnostics ++ file_diagnostics
  end

  def diagnostics_by_uri(%__MODULE__{} = state) do
    uris =
      state.entries_by_uri
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Map.keys(state.file_entries_by_uri)))

    Map.new(uris, &{&1, get(state, &1)})
  end

  def clear(%__MODULE__{} = state, source_uri) do
    file_entries = Map.put(state.file_entries_by_uri, source_uri, Entry.new(0))

    %__MODULE__{state | file_entries_by_uri: file_entries}
  end

  def clear_stale_project_diagnostics(%__MODULE__{} = state, source_uri) do
    case Document.Store.fetch(source_uri) do
      {:ok, %Document{dirty?: true}} ->
        entries_by_uri =
          Map.put(state.entries_by_uri, source_uri, Entry.new(0))

        %__MODULE__{state | entries_by_uri: entries_by_uri}

      _ ->
        state
    end
  end

  @doc """
  Clears project diagnostics for saved files, regardless of extension.
  Keeps diagnostics for unsaved files and file diagnostics for open scripts.
  """
  def clear_all_flushed(%__MODULE__{} = state) do
    entries_by_uri = clear_flushed(state.entries_by_uri, & &1.dirty?)

    file_entries_by_uri =
      clear_flushed(state.file_entries_by_uri, &keep_file_diagnostics?(&1, state.project))

    %__MODULE__{state | entries_by_uri: entries_by_uri, file_entries_by_uri: file_entries_by_uri}
  end

  def add(%__MODULE__{} = state, build_number, %Diagnostic{} = diagnostic) do
    entries_by_uri = add_to_entries(state.entries_by_uri, build_number, diagnostic)

    %__MODULE__{state | entries_by_uri: entries_by_uri}
  end

  def add(%__MODULE__{} = state, _build_number, other) do
    Logger.error("Invalid diagnostic: #{inspect(other)}")
    state
  end

  def add_file(%__MODULE__{} = state, build_number, %Diagnostic{} = diagnostic) do
    file_entries_by_uri = add_to_entries(state.file_entries_by_uri, build_number, diagnostic)

    %__MODULE__{state | file_entries_by_uri: file_entries_by_uri}
  end

  def add_file(%__MODULE__{} = state, _build_number, unknown) do
    Logger.error("Tried to add #{inspect(unknown)} as a diagnostic.")
    state
  end

  defp add_to_entries(entries_by_uri, build_number, diagnostic) do
    Map.update(
      entries_by_uri,
      diagnostic.uri,
      Entry.new(build_number, diagnostic),
      fn entry ->
        Entry.add(entry, build_number, diagnostic)
      end
    )
  end

  defp clear_flushed(entries_by_uri, keep_diagnostics?) do
    Map.new(entries_by_uri, fn {uri, %Entry{} = entry} ->
      with true <- Document.Store.open?(uri),
           {:ok, %Document{} = document} <- Document.Store.fetch(uri),
           true <- keep_diagnostics?.(document) do
        {uri, entry}
      else
        _ ->
          {uri, Entry.new(0)}
      end
    end)
  end

  defp keep_file_diagnostics?(%Document{} = document, project) do
    project_file? =
      Path.basename(document.path) == "mix.exs" or document.uri == project.mix_exs_uri

    document.dirty? or (script_file?(document) and not project_file?)
  end

  defp script_file?(document) do
    Path.extname(document.path) == ".exs"
  end
end
