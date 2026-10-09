defmodule Forge.Completion.CandidateTest do
  use ExUnit.Case, async: true

  alias Forge.Completion.Candidate

  test "preserves macro documentation from ElixirSense" do
    assert %Candidate.Macro{summary: "The resource attributes."} =
             Candidate.from_elixir_sense(%{
               type: :macro,
               name: "attributes",
               arity: 1,
               args: "body",
               origin: "Ash.Resource.Dsl",
               summary: "The resource attributes."
             })
  end

  test "converts generic ElixirSense fields" do
    assert %Candidate.Generic{
             label: "email",
             detail: "Ecto field",
             documentation: "The email field",
             kind: :field
           } =
             Candidate.from_elixir_sense(%{
               type: :generic,
               label: "email",
               detail: "Ecto field",
               documentation: "The email field",
               kind: :field
             })
  end
end
