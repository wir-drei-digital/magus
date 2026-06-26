defmodule Magus.Eval.Scoreboard do
  @moduledoc """
  Append-only, file-based persistence of eval runs, one JSONL file per
  benchmark under the configured results dir. Files are user-visible and
  diffable so iteration-over-iteration deltas are the trustworthy signal.
  """

  @doc "Append a run row. Returns the file path."
  def record(run, opts \\ []) when is_map(run) do
    dir = opts[:dir] || base_dir()
    File.mkdir_p!(dir)
    benchmark = Map.fetch!(run, :benchmark)
    path = Path.join(dir, "#{benchmark}.jsonl")
    row = run |> Map.put(:git_sha, git_sha()) |> Jason.encode!()
    File.write!(path, row <> "\n", [:append])
    {:ok, path}
  end

  @doc "Return the most recent `n` runs for a benchmark, newest first."
  def recent(benchmark, n, opts \\ []) do
    dir = opts[:dir] || base_dir()
    path = Path.join(dir, "#{benchmark}.jsonl")

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_row/1)
        |> Enum.reverse()
        |> Enum.take(n)

      _ ->
        []
    end
  end

  # Skip corrupt rows so one bad line does not crash reading a whole history.
  defp decode_row(line) do
    case Jason.decode(line) do
      {:ok, row} -> [row]
      {:error, _} -> []
    end
  end

  defp base_dir, do: Application.get_env(:magus, :eval_results_dir, "eval/results")

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end
