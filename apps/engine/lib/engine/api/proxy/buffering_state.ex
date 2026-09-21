defmodule Engine.Api.Proxy.BufferingState do
  import Engine.Api.Proxy.Records
  import Forge.EngineApi.Messages

  alias Engine.Build
  alias Forge.Document

  defstruct initiator_pid: nil, buffer: []

  def new(initiator_pid) do
    %__MODULE__{initiator_pid: initiator_pid}
  end

  def add_mfa(%__MODULE__{} = state, mfa() = mfa_record) do
    %__MODULE__{state | buffer: [mfa_record | state.buffer]}
  end

  def flush(%__MODULE__{} = state) do
    {messages, commands} =
      state.buffer
      |> Enum.reverse()
      |> Enum.split_with(fn value ->
        match?(mfa(module: Engine.Dispatch, function: :broadcast), value)
      end)

    {project_compile, document_compiles} = collapse_commands(commands)

    all_commands = [project_compile | Map.values(document_compiles)]

    all_commands
    |> Enum.concat(collapse_messages(messages, project_compile, document_compiles))
    |> Enum.filter(&match?(mfa(), &1))
    |> Enum.sort_by(fn mfa(seq: seq) -> seq end)
  end

  defp collapse_commands(commands) do
    # Rules for collapsing commands
    # 1. If there's a project compilation requested, remove all document compilations
    # 2. Formats can be dropped, as they're only valid for a short time.
    initial_state = %{project_compiles: [], document_compiles: %{}}

    grouped =
      commands
      |> Enum.reduce(
        initial_state,
        fn
          mfa(module: Build, function: :schedule_compile) = mfa, acc ->
            Map.update(acc, :project_compiles, [mfa], &[mfa | &1])

          mfa(module: Build, function: :compile_document) = mfa, acc ->
            mfa(arguments: [_, document]) = mfa
            uri = document.uri
            put_in(acc, [:document_compiles, uri], mfa)

          _, acc ->
            acc
        end
      )

    %{
      project_compiles: project_compiles,
      document_compiles: document_compiles
    } = grouped

    project_compile =
      Enum.reduce(project_compiles, nil, fn
        mfa(arguments: [_, true]) = mfa, _ ->
          mfa

        mfa(arguments: [true]) = mfa, _ ->
          mfa

        mfa() = mfa, nil ->
          mfa

        _, acc ->
          acc
      end)

    document_compiles =
      if project_compile do
        %{}
      else
        for {uri, indexed} <- document_compiles, Document.Store.open?(uri), into: %{} do
          {uri, indexed}
        end
      end

    {project_compile, document_compiles}
  end

  defp collapse_messages(messages, project_compile, document_compiles) do
    # Rules for collapsing messages
    # 1. If the message is document-centric, discard it if the document isn't open.
    # 2. It's probably safe to drop all file compile requested messages
    # 3. File diagnostics can be dropped if
    #   a. There is a document compile command for that uri
    #   b. There is a project compile requested
    # 4. Progress messages should still be sent to dispatch, even when buffering

    Enum.filter(messages, fn
      mfa(arguments: [file_compile_requested()]) ->
        false

      mfa(arguments: [project_compile_requested()]) ->
        false

      mfa(arguments: [file_diagnostics(uri: uri)]) ->
        not (Map.has_key?(document_compiles, uri) or
               match?(project_compile_requested(), project_compile))

      mfa(arguments: [body]) ->
        case fetch_uri(body) do
          {:ok, uri} ->
            Document.Store.open?(uri)

          :error ->
            true
        end
    end)
  end

  defp fetch_uri(filesystem_event(uri: uri)), do: {:ok, uri}
  defp fetch_uri(file_changed(uri: uri)), do: {:ok, uri}
  defp fetch_uri(file_compile_requested(uri: uri)), do: {:ok, uri}
  defp fetch_uri(file_compiled(uri: uri)), do: {:ok, uri}
  defp fetch_uri(file_deleted(uri: uri)), do: {:ok, uri}
  defp fetch_uri(file_diagnostics(uri: uri)), do: {:ok, uri}
  defp fetch_uri(_), do: :error
end
