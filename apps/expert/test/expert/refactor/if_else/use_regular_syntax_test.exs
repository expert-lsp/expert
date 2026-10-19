# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.IfElse.UseRegularSyntaxTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.IfElse.UseRegularSyntax

  test "refactors if statement with regular syntax" do
    assert_refactored(
      UseRegularSyntax,
      """
      # v
      if true, do: bar
      """,
      """
      if true do
        bar
      end
      """
    )
  end

  test "refactors if else statement with regular syntax" do
    assert_refactored(
      UseRegularSyntax,
      """
      # v
      if true,
        do: bar,
        else: bar + 10
      """,
      """
      if true do
        bar
      else
        bar + 10
      end
      """
    )
  end

  test "ignores if else statement already with regular syntax" do
    assert_ignored(
      UseRegularSyntax,
      """
      # v
      if true do
        bar
      else
        bar + 10
      end
      """
    )
  end
end
