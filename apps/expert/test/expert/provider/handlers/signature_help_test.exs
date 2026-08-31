defmodule Expert.Provider.Handlers.SignatureHelpTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.Fixtures

  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers.SignatureHelp
  alias Expert.State
  alias Forge.Document
  alias GenLSP.Requests.TextDocumentSignatureHelp
  alias GenLSP.Structures

  setup do
    start_supervised!(Expert.Application.document_store_child_spec())
    Expert.Configuration.new() |> Expert.Configuration.set()
    on_exit(fn -> :persistent_term.erase(Expert.Configuration) end)
  end

  test "forwards signature requests and builds an LSP response" do
    project = project()
    document = Document.new("file:///signature_help.ex", "Enum.map([1], nil)", 3)
    context = Context.new(document.uri, document, project)

    lsp_request =
      %TextDocumentSignatureHelp{
        id: 1,
        params: %Structures.SignatureHelpParams{
          text_document: %Structures.TextDocumentIdentifier{uri: document.uri},
          position: %Structures.Position{line: 0, character: 14}
        }
      }

    assert {:ok, request} = Convert.to_native(lsp_request, document)
    position = request.params.position

    patch(EngineApi, :signature_help, fn ^project, ^document, ^position ->
      %{
        active_param: 1,
        signatures: [
          %{
            active_param: 1,
            name: "map",
            params: ["enumerable", "fun"],
            spec: "@spec map(t(), (element() -> any())) :: list()",
            documentation: "Maps every element.",
            metadata: %{app: :elixir}
          }
        ]
      }
    end)

    assert {:ok,
            %Structures.SignatureHelp{
              active_signature: 0,
              active_parameter: 1,
              signatures: [
                %Structures.SignatureInformation{
                  active_parameter: 1,
                  label: "map(enumerable, fun)",
                  parameters: [
                    %Structures.ParameterInformation{label: "enumerable"},
                    %Structures.ParameterInformation{label: "fun"}
                  ],
                  documentation: %Structures.MarkupContent{kind: "markdown", value: markdown}
                }
              ]
            }} = SignatureHelp.handle(request, context)

    assert markdown =~ "**Application** elixir"
    assert markdown =~ "Maps every element."
    assert markdown =~ "```elixir"
    assert markdown =~ "@spec map"
  end

  test "returns nil when there is no call at the cursor" do
    project = project()
    document = Document.new("file:///signature_help.ex", "value = 1", 1)
    context = Context.new(document.uri, document, project)

    request =
      %TextDocumentSignatureHelp{
        id: 1,
        params: %Structures.SignatureHelpParams{
          text_document: %Structures.TextDocumentIdentifier{uri: document.uri},
          position: %Structures.Position{line: 0, character: 9}
        }
      }

    assert {:ok, request} = Convert.to_native(request, document)
    patch(EngineApi, :signature_help, fn ^project, ^document, _position -> :none end)

    assert {:ok, nil} = SignatureHelp.handle(request, context)
  end

  test "advertises signature help trigger characters" do
    assert %Structures.SignatureHelpOptions{trigger_characters: ["(", ","]} =
             State.initialize_result().capabilities.signature_help_provider
  end
end
