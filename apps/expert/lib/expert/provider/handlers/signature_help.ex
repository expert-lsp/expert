defmodule Expert.Provider.Handlers.SignatureHelp do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Provider.Markdown
  alias GenLSP.Requests
  alias GenLSP.Structures

  @trigger_characters ["(", ","]

  def trigger_characters, do: @trigger_characters

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentSignatureHelp{params: %Structures.SignatureHelpParams{} = params},
        %Context{} = context
      ) do
    %Context{document: document, project: project} = context

    response =
      case EngineApi.signature_help(project, document, params.position) do
        %{active_param: active_param, signatures: [_ | _] = signatures} ->
          %Structures.SignatureHelp{
            active_signature: 0,
            active_parameter: active_param,
            signatures: Enum.map(signatures, &signature_information/1)
          }

        _ ->
          nil
      end

    {:ok, response}
  end

  defp signature_information(%{name: name, params: params} = signature) do
    %Structures.SignatureInformation{
      label: "#{name}(#{Enum.join(params, ", ")})",
      parameters: Enum.map(params, &%Structures.ParameterInformation{label: &1}),
      active_parameter: Map.get(signature, :active_param),
      documentation: documentation(signature)
    }
  end

  defp documentation(signature) do
    content =
      Markdown.join_sections([
        metadata(Map.get(signature, :metadata)),
        Map.get(signature, :documentation),
        formatted_spec(Map.get(signature, :spec))
      ])

    if content != "", do: Markdown.to_content(content)
  end

  defp formatted_spec(spec) when spec in [nil, ""], do: nil

  defp formatted_spec(spec) do
    formatted =
      try do
        spec
        |> Code.format_string!(line_length: 42)
        |> IO.iodata_to_binary()
      rescue
        _ -> spec
      end

    Markdown.code_block(formatted)
  end

  defp metadata(metadata) when not is_map(metadata), do: nil

  defp metadata(metadata) do
    metadata
    |> Enum.sort()
    |> Enum.map(&metadata_entry/1)
    |> Markdown.join_sections()
  end

  defp metadata_entry({:app, app}) when is_atom(app) or is_binary(app),
    do: "**Application** #{app}"

  defp metadata_entry({:deprecated, message}) when is_binary(message),
    do: "**Deprecated** #{message}"

  defp metadata_entry({:deprecated, true}), do: "**Deprecated**"
  defp metadata_entry({:since, version}) when is_binary(version), do: "**Since** #{version}"
  defp metadata_entry({:guard, true}), do: "**Guard**"

  defp metadata_entry({:implementing, module}) when is_atom(module),
    do: "**Implementing behaviour** #{inspect(module)}"

  defp metadata_entry(_), do: nil
end
