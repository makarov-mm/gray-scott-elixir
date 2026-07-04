defmodule GrayScott.Strip do
  @moduledoc """
  One horizontal strip of the Gray-Scott grid, owned by one process.

  The strip holds `rows x cols` cells of two chemical fields U and V as
  lists of row-lists of floats. Every simulation step it receives halo
  rows (the edge rows of its vertical neighbours) from the coordinator
  and computes the 5-point Laplacian update.

  If the process is killed, the supervisor restarts it in the initial
  uniform state (U=1, V=0) — a visible "wound" in the pattern that the
  reaction-diffusion dynamics then heal from the neighbouring strips.
  """
  use GenServer

  # Gray-Scott parameters ("coral" regime)
  @du 0.16
  @dv 0.08
  @f 0.055
  @k 0.062

  def start_link({index, rows, cols}) do
    GenServer.start_link(__MODULE__, {index, rows, cols},
      name: {:via, Registry, {GrayScott.Registry, index}}
    )
  end

  @impl true
  def init({index, rows, cols}) do
    u = for _ <- 1..rows, do: List.duplicate(1.0, cols)
    v = for _ <- 1..rows, do: List.duplicate(0.0, cols)
    {:ok, %{index: index, rows: rows, cols: cols, u: u, v: v}}
  end

  # -- API used by the coordinator ------------------------------------

  @doc "Top and bottom edge rows of both fields, for halo exchange."
  def edges(pid), do: GenServer.call(pid, :edges)

  @doc "Run `n` simulation steps given the neighbour halos."
  def step(pid, halos), do: GenServer.call(pid, {:step, halos})

  @doc "V field of the strip as one flat binary of bytes (0..255)."
  def render(pid), do: GenServer.call(pid, :render)

  @doc "Drop a seed spot of V into the strip (used for initial seeding)."
  def seed(pid, col, radius), do: GenServer.call(pid, {:seed, col, radius})

  # -- callbacks -------------------------------------------------------

  @impl true
  def handle_call(:edges, _from, s) do
    {:reply,
     %{
       u_top: hd(s.u), u_bot: List.last(s.u),
       v_top: hd(s.v), v_bot: List.last(s.v)
     }, s}
  end

  def handle_call({:step, %{u_above: ua, u_below: ub, v_above: va, v_below: vb}}, _from, s) do
    {u2, v2} = step_fields(s.u, s.v, ua, ub, va, vb)
    {:reply, :ok, %{s | u: u2, v: v2}}
  end

  def handle_call(:render, _from, s) do
    bin =
      for row <- s.v, into: <<>> do
        for x <- row, into: <<>> do
          <<trunc(min(max(x, 0.0), 1.0) * 255.0)>>
        end
      end

    {:reply, bin, s}
  end

  def handle_call({:seed, col, radius}, _from, s) do
    mid = div(s.rows, 2)

    v2 =
      s.v
      |> Enum.with_index()
      |> Enum.map(fn {row, r} ->
        row
        |> Enum.with_index()
        |> Enum.map(fn {x, c} ->
          if abs(r - mid) <= radius and abs(c - col) <= radius, do: 0.9, else: x
        end)
      end)

    u2 =
      s.u
      |> Enum.with_index()
      |> Enum.map(fn {row, r} ->
        row
        |> Enum.with_index()
        |> Enum.map(fn {x, c} ->
          if abs(r - mid) <= radius and abs(c - col) <= radius, do: 0.4, else: x
        end)
      end)

    {:reply, :ok, %{s | u: u2, v: v2}}
  end

  # -- Gray-Scott math (pure, list-based) ------------------------------

  defp step_fields(u, v, u_above, u_below, v_above, v_below) do
    u_trios = trios(u, u_above, u_below)
    v_trios = trios(v, v_above, v_below)

    Enum.zip(u_trios, v_trios)
    |> Enum.map(fn {{up, uc, dn}, {vup, vc, vdn}} ->
      update_row(up, uc, dn, vup, vc, vdn)
    end)
    |> Enum.unzip()
  end

  # For every row: {row_above, row, row_below} with the halos at the ends.
  defp trios(rows, halo_top, halo_bot) do
    aboves = [halo_top | rows] |> Enum.drop(-1)
    belows = tl(rows) ++ [halo_bot]
    Enum.zip([aboves, rows, belows])
  end

  defp update_row(up, uc, dn, vup, vc, vdn) do
    u_left = rotate_right(uc)
    u_right = rotate_left(uc)
    v_left = rotate_right(vc)
    v_right = rotate_left(vc)

    update_cells(uc, up, dn, u_left, u_right, vc, vup, vdn, v_left, v_right, [], [])
  end

  # Hand-rolled 10-list recursion: the hot loop. Avoids the tuple
  # allocation of Enum.zip/1 — roughly 3x faster on this workload.
  defp update_cells([], _, _, _, _, [], _, _, _, _, uacc, vacc),
    do: {Enum.reverse(uacc), Enum.reverse(vacc)}

  defp update_cells(
         [u0 | t1], [un | t2], [us | t3], [uw | t4], [ue | t5],
         [v0 | t6], [vn | t7], [vs | t8], [vw | t9], [ve | t10],
         uacc, vacc
       ) do
    lap_u = un + us + uw + ue - 4.0 * u0
    lap_v = vn + vs + vw + ve - 4.0 * v0
    uvv = u0 * v0 * v0
    u1 = u0 + @du * lap_u - uvv + @f * (1.0 - u0)
    v1 = v0 + @dv * lap_v + uvv - (@f + @k) * v0
    update_cells(t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, [u1 | uacc], [v1 | vacc])
  end

  # toroidal wrap in X
  defp rotate_left([h | t]), do: t ++ [h]
  defp rotate_right(list), do: [List.last(list) | Enum.drop(list, -1)]
end
