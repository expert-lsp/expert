defmodule Expert.Search.Store.Backend do
  @moduledoc """
  Behaviour for project-scoped search store backends.
  """

  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @type version :: pos_integer()
  @type priv_state :: term()
  @type load_state :: :empty | :stale
  @type field_name :: atom()
  @type name :: term()
  @type wildcard :: :_
  @type subject_query :: Entry.subject() | wildcard()
  @type type_query :: Entry.entry_type() | wildcard()
  @type subtype_query :: Entry.entry_subtype() | wildcard()
  @type block_structure :: %{Entry.block_id() => block_structure()} | %{}
  @callback new(Project.t()) :: {:ok, priv_state()} | {:error, any()}
  @callback prepare(priv_state()) :: {:ok, load_state()} | {:error, any()}
  @callback sync(Project.t()) :: :ok | {:error, any()}
  @callback insert(Project.t(), [Entry.t()]) :: :ok | {:error, any()}
  @callback drop(Project.t()) :: boolean() | :ok | {:error, any()}
  @callback destroy(Project.t()) :: :ok | {:error, any()}
  @callback path_to_ids(Project.t()) :: %{Path.t() => Entry.entry_id()} | {:error, any()}
  @callback definitions_for_fuzzy(Project.t()) :: [Entry.t()] | {:error, any()}
  @callback replace_all(Project.t(), [Entry.t()]) :: :ok | {:error, any()}
  @callback delete_by_path(Project.t(), Path.t()) :: {:ok, [Entry.entry_id()]} | {:error, any()}
  @callback apply_index_update(Project.t(), [Entry.t()], [Path.t()]) ::
              {:ok, [Entry.entry_id()]} | {:error, any()}
  @callback structure_for_path(Project.t(), Path.t()) ::
              {:ok, block_structure()} | :error | {:error, any()}
  @callback find_by_subject(Project.t(), subject_query(), type_query(), subtype_query()) ::
              [
                Entry.t()
              ]
              | {:error, any()}
  @callback find_by_subjects(Project.t(), [Entry.subject()], type_query(), subtype_query()) ::
              [Entry.t()] | {:error, any()}
  @callback find_by_caller(Project.t(), Entry.caller(), Path.t(), type_query(), subtype_query()) ::
              [Entry.t()] | {:error, any()}
  @callback find_by_prefix(Project.t(), subject_query(), type_query(), subtype_query()) ::
              [
                Entry.t()
              ]
              | {:error, any()}
  @callback find_by_ids(Project.t(), [Entry.entry_id()], type_query(), subtype_query()) ::
              [
                Entry.t()
              ]
              | {:error, any()}
  @callback find_by_paths(Project.t(), [Path.t()], type_query(), subtype_query()) ::
              [Entry.t()] | {:error, any()}
  @callback siblings(Project.t(), Entry.t()) ::
              [Entry.t()] | :error | {:ok, [Entry.t()]} | {:error, any()}
  @callback parent(Project.t(), Entry.t()) :: {:ok, Entry.t()} | :error | {:error, any()}

  @optional_callbacks sync: 1
end
