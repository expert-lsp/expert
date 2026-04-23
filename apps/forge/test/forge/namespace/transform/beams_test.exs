defmodule Forge.Namespace.Transform.BeamsTest do
  use ExUnit.Case, async: false
  use Patch

  alias Forge.Namespace.Transform.Beams

  @moduletag tmp_dir: true

  describe "apply_to_all/2 crash handling" do
    test "raises when worker process crashes", %{tmp_dir: tmp_dir} do
      # We need total_files to be > 0 in block_until_done to enter the
      # receive loop
      File.mkdir_p!(Path.join([tmp_dir, "lib", "fake"]))
      File.write!(Path.join([tmp_dir, "lib", "fake", "Elixir.Fake.beam"]), "")

      patch(Mix.Tasks.Namespace, :app_names, [:fake])

      # Force a crash inside the worker. :beam_lib.chunks is the first
      # remote call in apply/1, so patching it sidesteps the with clause that
      # would otherwise handle a graceful error return.
      patch(:beam_lib, :chunks, fn _path, _chunks ->
        raise "simulated beam_lib crash"
      end)

      assert_raise RuntimeError, ~r/Beam rewriting worker crashed/, fn ->
        Beams.apply_to_all(tmp_dir, no_progress: true)
      end
    end
  end
end
