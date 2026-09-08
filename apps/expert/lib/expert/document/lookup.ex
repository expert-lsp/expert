defmodule Expert.Document.Lookup do
  @moduledoc """
  Finds the project that owns a document.

  Lookup first checks the projects that are already being tracked and picks the deepest project
  root that contains the file.

  If no tracked project matches, lookup walks upward on disk until it finds a `mix.exs`. That walk
  stops at the current workspace folder, if one contains the file.

  Files under `deps`, `_build`, and `.expert` are treated as part of the project above those
  directories. For example, lookup for `my_app/deps/foo/lib/foo.ex` starts from `my_app`, not from
  `my_app/deps/foo`.

  If the discovered Mix project is inside an umbrella, lookup returns the umbrella root instead of
  the child app.

  If no Mix project is found, lookup returns a bare project rooted at the workspace folder that
  contains the file, or at the file's parent directory when the file is outside any workspace.
  """

  alias Expert.Document.Context
  alias Forge.Document
  alias Forge.Project
  alias GenLSP.Structures

  @disallowed_segments ~w(deps _build .expert)

  @spec resolve(Forge.uri() | Document.t(), [Project.t()]) :: Context.t()
  def resolve(uri_or_document, projects)

  def resolve(uri, projects) when is_binary(uri) and is_list(projects) do
    document = load_document(uri)
    project = owning_project(projects, document.path, document.uri)
    Context.new(document.uri, document, project)
  end

  def resolve(%Document{} = document, projects) when is_list(projects) do
    project = owning_project(projects, document.path, document.uri)
    Context.new(document.uri, document, project)
  end

  @spec resolve_from_request(struct(), [Project.t()]) ::
          {:ok, Context.t()}
          | {:error, :document_not_found}
          | {:error, :invalid_call_hierarchy_item}
  def resolve_from_request(
        %request_module{
          params: %{item: %Structures.CallHierarchyItem{} = item}
        } = request,
        projects
      )
      when request_module in [
             GenLSP.Requests.CallHierarchyIncomingCalls,
             GenLSP.Requests.CallHierarchyOutgoingCalls
           ] do
    # For path dependencies in poncho projects, call hierarchy items will point to
    # a path in a different project. This will stop Call Hierarchy from working
    # properly, as requests to it will be handled by the dependency project instead
    # of the project that actually initiated the requests.
    with %{"project_root_uri" => root_uri} when is_binary(root_uri) <- item.data,
         %Project{} = project <- Enum.find(projects, &(&1.root_uri == root_uri)),
         {:ok, %Document{} = document} <- request_document(request) do
      {:ok, Context.new(document.uri, document, project)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_call_hierarchy_item}
    end
  end

  def resolve_from_request(request_or_params, projects) when is_list(projects) do
    with {:ok, %Document{} = document} <- request_document(request_or_params) do
      {:ok, resolve(document, projects)}
    end
  end

  @spec owning_project([Project.t()], String.t(), Forge.uri()) :: Project.t()
  def owning_project(projects, path, uri)
      when is_list(projects) and is_binary(path) and is_binary(uri) do
    project_for_path(projects, path) || discover_project(uri)
  end

  @spec projects_for_folders([Structures.WorkspaceFolder.t()]) :: [Project.t()]
  def projects_for_folders(folders) when is_list(folders) do
    folders
    |> Enum.map(fn
      %Structures.WorkspaceFolder{uri: uri} when is_binary(uri) ->
        case find_project_root_path(Document.Path.from_uri(uri)) do
          root_path when is_binary(root_path) -> Project.new(Document.Path.to_uri(root_path))
          nil -> nil
        end

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.root_uri)
  end

  @spec project_root_uris_for_paths([Path.t()]) :: MapSet.t(Forge.uri())
  def project_root_uris_for_paths(paths) when is_list(paths) do
    paths
    |> Enum.map(&find_project_root_path/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new(&Document.Path.to_uri/1)
  end

  @spec find_project_root_uri(Forge.uri()) :: Forge.uri() | nil
  def find_project_root_uri(uri) when is_binary(uri) do
    case find_project_root_path(Document.Path.from_uri(uri)) do
      root_path when is_binary(root_path) ->
        Document.Path.to_uri(root_path)

      nil ->
        nil
    end
  end

  @spec discover_project(Forge.uri()) :: Project.t()
  def discover_project(uri) when is_binary(uri) do
    path = Document.Path.from_uri(uri)

    case find_project_root_path(path) do
      root_path when is_binary(root_path) ->
        Project.new(Document.Path.to_uri(root_path))

      nil ->
        root_path = bare_project_root_path(path)
        Project.bare(Document.Path.to_uri(root_path))
    end
  end

  defp find_project_root_path(path) do
    path =
      path
      |> Path.expand()
      |> strip_dependency_segments()
      |> path_or_parent_dir()

    boundary = workspace_boundary_path(path)

    case find_mix_root(path, boundary) do
      root_path when is_binary(root_path) -> umbrella_root_for(root_path) || root_path
      nil -> nil
    end
  end

  defp bare_project_root_path(path), do: workspace_boundary_path(path) || path_or_parent_dir(path)

  defp project_for_path(projects, path) do
    projects
    |> Enum.filter(fn project ->
      case Project.root_path(project) do
        root_path when is_binary(root_path) -> Forge.Path.parent_path?(path, root_path)
        nil -> false
      end
    end)
    |> Enum.max_by(fn project -> project |> Project.root_path() |> byte_size() end, fn -> nil end)
  end

  defp strip_dependency_segments(path) do
    segments = Path.split(path)

    case Enum.find_index(segments, &(&1 in @disallowed_segments)) do
      nil ->
        path

      idx ->
        segments
        |> Enum.take(idx)
        |> Path.join()
    end
  end

  defp find_mix_root(path, boundary) do
    mix_exs_path = Path.join(path, "mix.exs")

    cond do
      boundary_reached?(path, boundary) ->
        nil

      File.exists?(mix_exs_path) ->
        path

      true ->
        parent_path = Path.dirname(path)

        if parent_path != path do
          find_mix_root(parent_path, boundary)
        end
    end
  end

  defp workspace_boundary_path(document_path) do
    case Forge.Workspace.get_workspace() do
      %Forge.Workspace{workspace_folders: workspace_folders} when workspace_folders != [] ->
        document_path = Path.expand(document_path)

        workspace_folders
        |> Enum.map(&Path.expand/1)
        |> Enum.filter(&Forge.Path.parent_path?(document_path, &1))
        |> Enum.max_by(&byte_size/1, fn -> nil end)

      _ ->
        nil
    end
  end

  defp boundary_reached?(_path, nil), do: false

  defp boundary_reached?(path, boundary) do
    expanded_path = Path.expand(path)
    not Forge.Path.parent_path?(expanded_path, boundary)
  end

  defp path_or_parent_dir(path) do
    if File.dir?(path) do
      path
    else
      Path.dirname(path)
    end
  end

  defp umbrella_root_for(project_path) do
    project_path = Path.expand(project_path)
    find_umbrella_root(Path.dirname(project_path), project_path)
  end

  defp find_umbrella_root(current_path, project_path) do
    case umbrella_apps_path(current_path) do
      apps_path when is_binary(apps_path) ->
        apps_root = Path.expand(Path.join(current_path, apps_path))

        if project_path == apps_root or Forge.Path.parent_path?(project_path, apps_root) do
          current_path
        else
          next_umbrella_parent(current_path, project_path)
        end

      nil ->
        next_umbrella_parent(current_path, project_path)
    end
  end

  defp next_umbrella_parent(current_path, project_path) do
    parent_path = Path.dirname(current_path)

    if parent_path != current_path do
      find_umbrella_root(parent_path, project_path)
    end
  end

  defp umbrella_apps_path(project_path) when is_binary(project_path) do
    mix_exs_path = Path.join(project_path, "mix.exs")

    with true <- File.exists?(mix_exs_path),
         {:ok, source} <- File.read(mix_exs_path),
         {:ok, ast} <- Code.string_to_quoted(source),
         apps_path when is_binary(apps_path) <- extract_apps_path(ast) do
      apps_path
    else
      _ -> nil
    end
  end

  defp extract_apps_path(ast) do
    {_ast, apps_path} =
      Macro.prewalk(ast, nil, fn
        {:apps_path, value} = node, nil when is_binary(value) -> {node, value}
        node, acc -> {node, acc}
      end)

    apps_path
  end

  defp load_document(uri) do
    case fetch_or_open_document(uri) do
      {:ok, %Document{} = document} ->
        document

      _ ->
        Document.new(uri, "", 0)
    end
  end

  defp request_document(request_or_params) do
    case extract_uri(request_or_params) do
      uri when is_binary(uri) ->
        case fetch_or_open_document(uri) do
          {:ok, %Document{} = document} -> {:ok, document}
          _ -> {:error, :document_not_found}
        end

      nil ->
        case Document.Container.context_document(request_or_params, nil) do
          %Document{} = document -> {:ok, document}
          _ -> {:error, :document_not_found}
        end
    end
  end

  defp fetch_or_open_document(uri) do
    with {:error, _} <- Document.Store.fetch(uri) do
      Document.Store.open_temporary(uri)
    end
  end

  defp extract_uri(%{item: %GenLSP.Structures.CallHierarchyItem{uri: uri}}) when is_binary(uri),
    do: uri

  defp extract_uri(%{text_document: %{uri: uri}}) when is_binary(uri), do: uri
  defp extract_uri(%{uri: uri}) when is_binary(uri), do: uri
  defp extract_uri(%{params: params}) when is_map(params), do: extract_uri(params)
  defp extract_uri(%{data: %{"uri" => uri}}) when is_binary(uri), do: uri
  defp extract_uri(_), do: nil
end
