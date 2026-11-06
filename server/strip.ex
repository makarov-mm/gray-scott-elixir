defmodule GrayScott.Strip do
  @moduledoc """
  One horizontal strip of the Gray-Scott grid, owned by one process.

  The strip holds `rows x cols` cells of the two chemical fields U and V as
  lists of row-lists of floats. Every simulation step it receives halo rows
  (the edge rows of its vertical neighbours) from the coordinator, computes
  the 5-point Laplacian update and replies with its own new edge rows, so
  the next step needs no separate edge round-trip.

  If the process is killed, the supervisor restarts it in the initial
  uniform state (U=1, V=0) - a visible "wound" in the pattern that the
  reaction-diffusion dynamics then heal from the neighbouring strips.
  """
  use GenServer

  # Gray-Scott parameters ("coral" regime)
  @du 0.16
  @dv 0.08
  @f 0.055
  @k 0.062

  # Seed spot: V raised to @seed_v and U lowered to @seed_u in a square of
  # half-width `radius` around the strip's middle row
  @seed_u 0.4
  @seed_v 0.9

  @typedoc "Edge rows of both fields, as sent to the vertical neighbours."
  @type edges :: %{u_top: [float], u_bot: [float], v_top: [float], v_bot: [float]}

  @typedoc "Halo rows received from the vertical neighbours."
  @type halos :: %{u_above: [float], u_below: [float], v_above: [float], v_below: [float]}

  def start_link({index, rows, cols}) do
    GenServer.start_link(__MODULE__, {index, rows, cols}, name: via(index))
  end

  @doc "Registry name of strip `index`."
  def via(index), do: {:via, Registry, {GrayScott.Registry, index}}

  # -- API used by the coordinator ------------------------------------

  @doc "Top and bottom edge rows of both fields, for halo exchange."
  @spec edges(pid) :: edges
  def edges(pid), do: GenServer.call(pid, :edges)

  @doc "Run one simulation step given the neighbour halos; returns the new edges."
  @spec step(pid, halos) :: edges
  def step(pid, halos), do: GenServer.call(pid, {:step, halos})

  @doc "V field of the strip as one flat binary of bytes (0..255), row-major."
  @spec render(pid) :: binary
  def render(pid), do: GenServer.call(pid, :render)

  @doc "Drop a seed spot of V into the strip around column `col`."
  @spec seed(pid, non_neg_integer, non_neg_integer) :: :ok
  def seed(pid, col, radius), do: GenServer.call(pid, {:seed, col, radius})

  # -- callbacks -------------------------------------------------------

  @impl true
  def init({index, rows, cols}) do
    u = for _ <- 1..rows, do: List.duplicate(1.0, cols)
    v = for _ <- 1..rows, do: List.duplicate(0.0, cols)
    {:ok, %{index: index, rows: rows, cols: cols, u: u, v: v}}
  end

  @impl true
  def handle_call(:edges, _from, state) do
    {:reply, edges_of(state), state}
  end

  def handle_call({:step, halos}, _from, state) do
    {u, v} = step_fields(state.u, state.v, halos)
    state = %{state | u: u, v: v}
    {:reply, edges_of(state), state}
  end

  def handle_call(:render, _from, state) do
    bytes = for row <- state.v, x <- row, into: <<>>, do: <<quantize(x)>>
    {:reply, bytes, state}
  end

  def handle_call({:seed, col, radius}, _from, state) do
    mid = div(state.rows, 2)
    inside? = fn r, c -> abs(r - mid) <= radius and abs(c - col) <= radius end
    u = stamp(state.u, inside?, @seed_u)
    v = stamp(state.v, inside?, @seed_v)
    {:reply, :ok, %{state | u: u, v: v}}
  end

  defp edges_of(%{u: u, v: v}) do
    %{u_top: hd(u), u_bot: List.last(u), v_top: hd(v), v_bot: List.last(v)}
  end

  # V is clamped to 0..1 and scaled to a byte
  defp quantize(x), do: trunc(min(max(x, 0.0), 1.0) * 255.0)

  # Overwrites the cells for which `inside?.(row, col)` holds
  defp stamp(rows, inside?, value) do
    for {row, r} <- Enum.with_index(rows) do
      for {x, c} <- Enum.with_index(row), do: if(inside?.(r, c), do: value, else: x)
    end
  end

  # -- Gray-Scott math (pure, list-based) ------------------------------

  # Explicit Euler step of
  #   dU/dt = Du lap(U) - U V^2 + F (1 - U)
  #   dV/dt = Dv lap(V) + U V^2 - (F + k) V
  # on a torus: rows wrap through the neighbour halos, columns wrap
  # inside each row.
  defp step_fields(u, v, %{u_above: ua, u_below: ub, v_above: va, v_below: vb}) do
    Enum.zip_with([trios(u, ua, ub), trios(v, va, vb)], fn [{un, uc, us}, {vn, vc, vs}] ->
      update_row(uc, un, us, vc, vn, vs)
    end)
    |> Enum.unzip()
  end

  # For every row: {row_above, row, row_below}, with the halos at the ends
  defp trios(rows, halo_top, halo_bot) do
    aboves = [halo_top | Enum.drop(rows, -1)]
    belows = tl(rows) ++ [halo_bot]
    Enum.zip([aboves, rows, belows])
  end

  defp update_row(uc, un, us, vc, vn, vs) do
    # The left neighbour of the first cell and the right neighbour of the
    # last one wrap around the row
    update_cells(uc, un, us, vc, vn, vs, List.last(uc), List.last(vc), hd(uc), hd(vc), [], [])
  end

  # The hot loop: six parallel lists, with the left neighbours carried
  # along (`uw`, `vw`) and the right ones peeked from the tails, so a row
  # costs no rotated copies and no tuple allocation per cell.
  defp update_cells([], [], [], [], [], [], _uw, _vw, _u_first, _v_first, uacc, vacc) do
    {Enum.reverse(uacc), Enum.reverse(vacc)}
  end

  defp update_cells(
         [u0 | ut], [un | unt], [us | ust],
         [v0 | vt], [vn | vnt], [vs | vst],
         uw, vw, u_first, v_first, uacc, vacc
       ) do
    ue = right_neighbour(ut, u_first)
    ve = right_neighbour(vt, v_first)
    lap_u = un + us + uw + ue - 4.0 * u0
    lap_v = vn + vs + vw + ve - 4.0 * v0
    uvv = u0 * v0 * v0
    u1 = u0 + @du * lap_u - uvv + @f * (1.0 - u0)
    v1 = v0 + @dv * lap_v + uvv - (@f + @k) * v0
    update_cells(ut, unt, ust, vt, vnt, vst, u0, v0, u_first, v_first, [u1 | uacc], [v1 | vacc])
  end

  defp right_neighbour([], first), do: first
  defp right_neighbour([x | _], _first), do: x
end
