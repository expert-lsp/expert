defmodule Forge.EngineApi.Messages do
  import Record

  alias Forge.Project

  defrecord :project_compile_requested, project: nil, build_number: 0

  defrecord :project_compiled,
    project: nil,
    build_number: 0,
    status: :successful,
    diagnostics: [],
    elapsed_ms: 0

  defrecord :filesystem_event, project: nil, uri: nil, event_type: nil

  defrecord :file_changed, uri: nil, from_version: nil, to_version: nil, open?: false

  defrecord :file_compile_requested, project: nil, build_number: 0, uri: nil

  defrecord :file_compiled,
    project: nil,
    build_number: 0,
    uri: nil,
    status: :successful,
    diagnostics: [],
    elapsed_ms: 0

  defrecord :file_deleted, project: nil, uri: nil

  defrecord :file_saved, uri: nil

  defrecord :module_updated, file: nil, name: nil, functions: [], macros: [], struct: nil

  defrecord :project_diagnostics, project: nil, build_number: 0, diagnostics: []

  defrecord :file_diagnostics, project: nil, build_number: 0, uri: nil, diagnostics: []

  defrecord :struct_discovered, module: nil, fields: []

  defrecord :project_index_ready, project: nil

  defrecord :project_reindex_requested, project: nil

  defrecord :project_reindexed, project: nil, elapsed_ms: 0, status: :success

  defrecord :search_store_loading, project: nil

  @type compile_status :: :successful | :error
  @type name_and_arity :: {atom, non_neg_integer}
  @type field_list :: Keyword.t() | [atom]
  @type diagnostics :: [Forge.Diagnostic.t()]
  @type maybe_version :: nil | non_neg_integer()

  @type project_compile_requested ::
          record(:project_compile_requested,
            project: Forge.Project.t(),
            build_number: non_neg_integer()
          )
  @type project_compiled ::
          record(:project_compiled,
            project: Forge.Project.t(),
            build_number: non_neg_integer(),
            status: compile_status,
            elapsed_ms: non_neg_integer
          )

  @type filesystem_event ::
          record(:filesystem_event,
            project: Project.t(),
            uri: Forge.uri(),
            event_type: :created | :updated | :deleted
          )

  @type file_changed ::
          record(:file_changed,
            uri: Forge.uri(),
            from_version: maybe_version,
            to_version: maybe_version,
            open?: boolean()
          )

  @type file_compile_requested ::
          record(:file_compile_requested,
            project: Forge.Project.t(),
            build_number: non_neg_integer(),
            uri: Forge.uri()
          )

  @type file_compiled ::
          record(:file_compiled,
            project: Forge.Project.t(),
            build_number: non_neg_integer(),
            uri: Forge.uri(),
            status: compile_status,
            elapsed_ms: non_neg_integer
          )

  @type file_saved :: record(:file_saved, uri: Forge.uri())

  @type module_updated ::
          record(:module_updated,
            name: module(),
            functions: [name_and_arity],
            macros: [name_and_arity],
            struct: field_list
          )

  @type project_diagnostics ::
          record(:project_diagnostics,
            project: Forge.Project.t(),
            diagnostics: diagnostics()
          )

  @type file_diagnostics ::
          record(:file_diagnostics,
            project: Forge.Project.t(),
            uri: Forge.uri(),
            diagnostics: diagnostics()
          )

  @type struct_discovered :: record(:struct_discovered, module: module(), fields: field_list())

  @type project_index_ready :: record(:project_index_ready, project: Forge.Project.t())

  @type project_reindex_requested ::
          record(:project_reindex_requested, project: Forge.Project.t())

  @type project_reindexed ::
          record(:project_reindexed,
            project: Forge.Project.t(),
            elapsed_ms: non_neg_integer(),
            status: :success | {:error, term()}
          )

  @type search_store_loading ::
          record(:search_store_loading, project: Forge.Project.t())
end
