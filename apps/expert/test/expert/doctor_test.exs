defmodule Expert.DoctorTest do
  use ExUnit.Case, async: false
  use Patch

  import ExUnit.CaptureIO

  alias Expert.Doctor

  @moduletag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    cache_dir = Path.join(tmp_dir, "cache")
    File.mkdir_p!(cache_dir)
    patch(Forge.Path, :expert_cache_dir, cache_dir)

    {:ok, cache_dir: cache_dir}
  end

  describe "run/1 --help and -h" do
    test "prints usage and returns 0" do
      for flag <- ["--help", "-h"] do
        output =
          capture_io(fn ->
            exit_code = Doctor.run([flag])
            assert exit_code == 0
          end)

        assert output =~ "Diagnose and inspect environment & system health"
        assert output =~ "expert doctor [options]"
        assert output =~ "--project"
      end
    end
  end

  describe "run/1 diagnostic checks" do
    test "runs successfully on healthy system", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          exit_code = Doctor.run(["--project", tmp_dir])
          assert exit_code == 0
        end)

      assert output =~ "Expert Doctor v"
      assert output =~ "System & Runtime:"
      assert output =~ "Elixir:"
      assert output =~ "Erlang/OTP:"
      assert output =~ "Subsystems:"
      assert output =~ "SQLite (Exqlite):   ok (SQLite v"
      assert output =~ "EPMD Module:"
      assert output =~ "Global Cache:"
      assert output =~ "0 builds"
      assert output =~ "Project:"
      assert output =~ "All critical checks passed."
    end

    test "reports project with mix.exs and .expert directory", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "my_project")
      File.mkdir_p!(Path.join(project_dir, ".expert"))
      File.write!(Path.join(project_dir, "mix.exs"), "defmodule MyProject.MixProject do\nend")
      File.write!(Path.join(project_dir, ".expert/index.db"), String.duplicate("0", 2048))

      output =
        capture_io(fn ->
          exit_code = Doctor.run(["-p", project_dir])
          assert exit_code == 0
        end)

      assert output =~ "Mix Project:        detected"
      assert output =~ "Local .expert:      present (2.0 KB)"
    end

    test "reports cached engines and hex metadata when present", %{
      cache_dir: cache_dir,
      tmp_dir: tmp_dir
    } do
      engine_dir = Path.join(cache_dir, "0.1.11/erl-29_elixir-1.20")
      File.mkdir_p!(engine_dir)
      File.write!(Path.join(cache_dir, "hex.dets"), String.duplicate("h", 1024))

      output =
        capture_io(fn ->
          exit_code = Doctor.run(["--project", tmp_dir])
          assert exit_code == 0
        end)

      assert output =~ "Cached Engines:     1 build(s)"
      assert output =~ "0.1.11/erl-29_elixir-1.20"
      assert output =~ "Hex Metadata:       present (1.0 KB)"
    end

    test "returns exit code 1 when SQLite fails", %{tmp_dir: tmp_dir} do
      patch(Exqlite.Basic, :open, fn _path -> {:error, :nif_not_loaded} end)

      output =
        capture_io(fn ->
          exit_code = Doctor.run(["--project", tmp_dir])
          assert exit_code == 1
        end)

      assert output =~ "SQLite (Exqlite):   failed (:nif_not_loaded)"
      assert output =~ "Critical subsystem errors detected."
    end
  end
end
