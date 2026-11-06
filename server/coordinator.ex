defmodule GrayScott.Coordinator do
  @moduledoc """
  Orchestrates the strips: distributes halo rows, runs the simulation
  steps in parallel (one Task per strip, so every strip can use its own
  scheduler), assembles the full V field for the renderer.

  Each step reply carries the strip's new edge rows, which are the halos
  of the next step - one call per strip per step. Edges are re-fetched
  only for strips without a cached reply (fresh start, restarted after a
  crash, or after a seed command touched the cells).

  A strip can die at any moment (that is the demo). Every interaction
  with a strip tolerates `:noproc`/`:killed` - a dead strip is simply
  skipped for one step and rejoins after the supervisor restarts it. Its
  neighbours skip that step too, since their halo is missing.
  """
  require Logger

  alias GrayScott.Strip

  @step_timeout 5_000

  @typedoc "Cached edge rows by strip index, threaded through `step_all/2`."
  @type edge_cache :: %{non_neg_integer => Strip.edges()}

  @doc """
  One synchronized simulation step across all strips. Returns the edge
  cache for the next step; start with `%{}`.
  """
  @spec step_all(pos_integer, edge_cache) :: edge_cache
  def step_all(n_strips, cache \\ %{}) do
    pids = strip_pids(n_strips)

    edges =
      for {pid, i} <- Enum.with_index(pids), into: %{} do
        {i, if(pid, do: cache[i] || safe(fn -> Strip.edges(pid) end))}
      end

    # A strip steps only when it and both its vertical neighbours are alive
    tasks =
      for {pid, i} <- Enum.with_index(pids), into: %{} do
        above = edges[Integer.mod(i - 1, n_strips)]
        below = edges[Integer.mod(i + 1, n_strips)]

        task =
          if pid && above && below do
            halos = %{u_above: above.u_bot, v_above: above.v_bot, u_below: below.u_top, v_below: below.v_top}
            Task.async(fn -> safe(fn -> Strip.step(pid, halos) end) end)
          end

        {i, task}
      end

    for {i, task} <- tasks, task, reduce: %{} do
      acc ->
        case Task.await(task, @step_timeout) do
          nil -> acc
          new_edges -> Map.put(acc, i, new_edges)
        end
    end
  end

  @doc """
  Full V field as one binary (strip order top to bottom). A freshly
  restarted (or dead) strip renders as zeros.
  """
  @spec render_frame(pos_integer, pos_integer, pos_integer) :: binary
  def render_frame(n_strips, rows_per_strip, cols) do
    blank = :binary.copy(<<0>>, rows_per_strip * cols)

    n_strips
    |> strip_pids()
    |> Enum.map(fn
      nil -> blank
      pid -> safe(fn -> Strip.render(pid) end) || blank
    end)
    |> IO.iodata_to_binary()
  end

  @doc "Kill a random strip process. The supervisor restarts it blank."
  @spec chaos(pos_integer) :: :ok
  def chaos(n_strips) do
    case live_strips(n_strips) do
      [] ->
        :ok

      strips ->
        {index, pid} = Enum.random(strips)
        Logger.info("chaos: killing strip #{index} (#{inspect(pid)})")
        Process.exit(pid, :kill)
        :ok
    end
  end

  @doc "Drop `count` seed spots of V into random strips at random columns."
  @spec seed(pos_integer, pos_integer, pos_integer) :: :ok
  def seed(n_strips, cols, count) do
    case live_strips(n_strips) do
      [] ->
        :ok

      strips ->
        for _ <- 1..count do
          {_index, pid} = Enum.random(strips)
          safe(fn -> Strip.seed(pid, :rand.uniform(cols) - 1, 3) end)
        end

        :ok
    end
  end

  # ---------------------------------------------------------------

  # pid of every strip by index, nil where the strip is (re)starting
  defp strip_pids(n_strips) do
    for i <- 0..(n_strips - 1) do
      case Registry.lookup(GrayScott.Registry, i) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end
  end

  defp live_strips(n_strips) do
    for {pid, i} <- Enum.with_index(strip_pids(n_strips)), pid, do: {i, pid}
  end

  # A pid can die between "found in the registry" and "called": the call
  # then exits, and the strip is treated as absent for this step
  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> nil
  end
end
