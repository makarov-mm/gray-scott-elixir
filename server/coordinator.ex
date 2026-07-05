defmodule GrayScott.Coordinator do
  @moduledoc """
  Orchestrates the strips: collects edge rows, distributes halos, runs
  simulation steps in parallel (one Task per strip = one scheduler per
  strip), assembles the full V field for the renderer.

  A strip can die at any moment (that is the demo). Every interaction
  with a strip tolerates `:noproc`/`:killed` — a dead strip is simply
  skipped for one step and rejoins after the supervisor restarts it.
  """

  @doc "One synchronized simulation step across all strips."
  def step_all(n_strips) do
    pids = strip_pids(n_strips)
    edges = Enum.map(pids, &safe(fn -> GrayScott.Strip.edges(&1) end))

    pids
    |> Enum.with_index()
    |> Enum.map(fn {pid, i} ->
      above = neighbour_edge(edges, i - 1, n_strips, :bot)
      below = neighbour_edge(edges, i + 1, n_strips, :top)

      case {pid, above, below} do
        {nil, _, _} -> nil
        {_, nil, _} -> nil
        {_, _, nil} -> nil
        _ ->
          Task.async(fn ->
            safe(fn ->
              GrayScott.Strip.step(pid, %{
                u_above: above.u, v_above: above.v,
                u_below: below.u, v_below: below.v
              })
            end)
          end)
      end
    end)
    |> Enum.each(fn
      nil -> :ok
      task -> Task.await(task, 5000)
    end)
  end

  @doc "Full V field as one binary (strip order top to bottom).
  A freshly restarted (or dead) strip renders as zeros."
  def render_frame(n_strips, rows_per_strip, cols) do
    blank = :binary.copy(<<0>>, rows_per_strip * cols)

    strip_pids(n_strips)
    |> Enum.map(fn
      nil -> blank
      pid -> safe(fn -> GrayScott.Strip.render(pid) end) || blank
    end)
    |> IO.iodata_to_binary()
  end

  @doc "Kill a random strip process. The supervisor restarts it blank."
  def chaos(n_strips) do
    case strip_pids(n_strips) |> Enum.reject(&is_nil/1) do
      [] -> :ok
      pids ->
        victim = Enum.random(pids)
        IO.puts("chaos: killing strip #{inspect(victim)}")
        Process.exit(victim, :kill)
    end
  end

  @doc "Seed V spots across random strips."
  def seed(n_strips, cols, count \\ 6) do
    pids = strip_pids(n_strips) |> Enum.reject(&is_nil/1)

    for _ <- 1..count do
      pid = Enum.random(pids)
      safe(fn -> GrayScott.Strip.seed(pid, :rand.uniform(cols) - 1, 3) end)
    end

    :ok
  end

  # ---------------------------------------------------------------

  defp strip_pids(n_strips) do
    for i <- 0..(n_strips - 1) do
      case Registry.lookup(GrayScott.Registry, i) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end
  end

  # toroidal wrap in Y across strips
  defp neighbour_edge(edges, i, n, side) do
    case Enum.at(edges, Integer.mod(i, n)) do
      nil -> nil
      e ->
        case side do
          :bot -> %{u: e.u_bot, v: e.v_bot}
          :top -> %{u: e.u_top, v: e.v_top}
        end
    end
  end

  defp safe(fun) do
    try do
      fun.()
    catch
      :exit, _ -> nil
    end
  end
end
