defmodule LexibombServer.Board do
  @moduledoc """
  Maintains the state of game boards and provides the high-level public API for
  interacting with them throughout gameplay.

  A default Lexibomb board consists of a 15 x 15 grid of squares. The squares
  are referred to using a coordinate system where the rows are numbered
  1 through 15, and the columns are lettered "a" through "o". A number combined
  with a letter specify a square on the board.

  A "seed" value is stored with each board and used to seed the pseudorandom
  number generator (PRNG) whenever randomness is required. This adds the option
  for functional determinism when necessary.
  """

  defstruct [:grid, :seed]

  alias LexibombServer.Board.Grid
  alias LexibombServer.Play
  alias LexibombServer.Utils

  @type coord :: Grid.coord | {non_neg_integer, String.t} | String.t
  @type seed :: {integer, integer, integer}
  @type board_options :: [size: pos_integer, seed: seed, bomb_count: pos_integer]
  @type t :: %{grid: Grid.t, seed: seed}

  @default_size 15
  @default_bomb_count 22

  @doc """
  Starts an agent linked to the current process, storing the state of a new
  board.

  ## Examples

      iex> {:ok, pid} = LexibombServer.Board.start_link
      iex> is_pid(pid)
      true

  ## Options

  Same as `new/1`.
  """
  @spec start_link :: Agent.on_start
  def start_link(opts \\ []) do
    Agent.start_link(fn -> new(opts) end)
  end

  @doc """
  Creates a new game board with the given options.

  ## Options

  The accepted options are:

    * `:size` - create a board of the given size; the default is #{@default_size}
    * `:seed` - a seed for the PRNG; the default is a uniquely generated seed
    * `:bomb_count` - the number of bombs to randomly place on the board;
       the default is #{@default_bomb_count}
  """
  @spec new(board_options) :: t
  def new(opts \\ []) do
    size = opts |> Keyword.get(:size, @default_size)
    seed = opts |> Keyword.get(:seed, Utils.unique_seed)
    bomb_count = opts |> Keyword.get(:bomb_count, @default_bomb_count)

    %LexibombServer.Board{grid: Grid.init(size), seed: seed}
    |> place_random_bombs(bomb_count)
  end

  @doc """
  Retrieves the board's state from the given process.
  """
  @spec get(pid) :: t
  def get(pid) do
    Agent.get(pid, &(&1))
  end

  @doc """
  Stores the state of `board` in the given process.
  """
  @spec set(t, pid) :: :ok
  def set(%LexibombServer.Board{} = board, pid) do
    Agent.update(pid, fn _ -> board end)
  end

  @doc """
  Returns the size of the game board.

  The "size", is the number of squares along a single dimension of the board.
  """
  @spec size(pid) :: pos_integer
  def size(pid) do
    Agent.get(pid, fn board ->
      Grid.board_size(board.grid)
    end)
  end

  @doc """
  Places a bomb on the board square at the given coordinate.

  Returns `:ok` on success, or `{:error, :badarg}` on failure.
  """
  @spec place_bomb(pid, coord) :: :ok | {:error, :badarg}
  def place_bomb(pid, coord) do
    place_bombs(pid, [coord])
  end

  @doc """
  Places a bomb on each of the board squares at the given coordinates.

  Returns `:ok` on success, or `{:error, :badarg}` on failure.
  """
  @spec place_bombs(pid, [coord]) :: :ok | {:error, :badarg}
  def place_bombs(pid, coords) do
    parsed_coords = coords |> Enum.map(&parse_coord/1)

    any_errors? =
      Enum.any?(parsed_coords, fn coord ->
        match?({:error, _}, coord)
      end)

    if any_errors? do
      {:error, :badarg}
    else
      parsed_coords
      |> Keyword.values
      |> do_place_bombs(pid)
    end
  end

  @spec do_place_bombs([Grid.coord], pid) :: :ok
  defp do_place_bombs(coords, pid) do
    Agent.update(pid, fn board ->
      %{board | grid: Grid.place_bombs(board.grid, coords)}
    end)
  end

  @doc """
  Places a bomb on `count` number of randomly selected board squares.

  The board's PRNG seed is used to make this operation idempotent.
  """
  @spec place_random_bombs(t, pos_integer) :: t
  def place_random_bombs(%LexibombServer.Board{} = board, count \\ @default_bomb_count) do
    _ = Utils.seed_the_prng(board.seed)

    coords =
      board.grid
      |> Grid.active_squares
      |> Map.keys
      |> Enum.take_random(count)

    %{board | grid: Grid.place_bombs(board.grid, coords)}
  end

  @doc """
  Places a tile on the board square at the given coordinate.

  Returns `:ok` on success, or `{:error, :badarg}` on failure.
  """
  @spec place_tile(pid, coord, String.t) :: :ok | {:error, :badarg}
  def place_tile(pid, coord, tile) when byte_size(tile) === 1 do
    case parse_coord(coord) do
      {:ok, coord} ->
        do_place_tile(pid, coord, tile)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec do_place_tile(pid, Grid.coord, String.t) :: :ok
  defp do_place_tile(pid, coord, tile) do
    Agent.update(pid, fn board ->
      %{board | grid: Grid.place_tile(board.grid, coord, tile)}
    end)
  end

  @doc """
  Parses and normalizes the given coordinate.

  It will parse any of the valid `LexibombServer.Board.coord` forms and will
  normalize them to the underlying `LexibombServer.Board.Grid.coord` type. If
  indicating the column with a string, you can use either uppercase or
  lowercase letters, and you may also optionally separate the row and column
  with whitespace.

  Both `row` and `col` must parse into non-negative integers for success.

  ## Examples

      iex> LexibombServer.Board.parse_coord "10B"
      {:ok, {10, 2}}

      iex> LexibombServer.Board.parse_coord "10 b"
      {:ok, {10, 2}}

      iex> LexibombServer.Board.parse_coord {10, "B"}
      {:ok, {10, 2}}

      iex> LexibombServer.Board.parse_coord {10, 2}
      {:ok, {10, 2}}

      iex> LexibombServer.Board.parse_coord {-10, 2}
      {:error, :badarg}

      iex> LexibombServer.Board.parse_coord {"B", 10}
      {:error, :badarg}

  Returns `{:ok, {row, col}}` on success, or `{:error, :badarg}` on failure.
  """
  @spec parse_coord(coord) :: {:ok, Grid.coord} | {:error, :badarg}
  def parse_coord(coord) when is_binary(coord) do
    {row_string, letter} = coord |> String.split_at(-1)

    try do
      row_string
      |> String.rstrip
      |> String.to_integer
    catch
      :error, :badarg -> {:error, :badarg}
    else
      row -> parse_coord({row, letter})
    end
  end

  def parse_coord({row, letter}) when is_integer(row) and is_binary(letter) do
    col = letter_to_col(letter)
    case col do
      :error ->
        {:error, :badarg}
      _ ->
        parse_coord({row, col})
    end
  end

  def parse_coord({row, col}) when is_integer(row) and is_integer(col) do
    if Enum.all?([row, col], &(&1 >= 0)) do
      {:ok, {row, col}}
    else
      {:error, :badarg}
    end
  end

  def parse_coord(_coord), do: {:error, :badarg}

  @doc """
  Make a play of tiles on the board.
  """
  @spec make_play(pid, LexibombServer.Play.t) :: :ok | {:error, :badarg}
  def make_play(pid, play) do
    with {:ok, placements} <- Play.letters_with_coords(play),
      do: Enum.each(placements, fn {tile, coord} ->
            do_place_tile(pid, coord, tile)
          end)
  end

  @doc """
  Returns `true` if the given coordinate points to an anchor square.
  """
  @spec anchor_square?(pid, coord) :: boolean
  def anchor_square?(pid, coord) do
    result =
      with {:ok, coord} <- parse_coord(coord),
           grid = get(pid).grid,
        do: Grid.anchor_square?(grid, coord)

    case result do
      {:error, _} -> false
      _ -> result
    end
  end

  @doc """
  Returns a list of all the coordinates on the board that are anchor squares.
  """
  @spec all_anchor_squares(pid) :: [Grid.coord]
  def all_anchor_squares(pid) do
    get(pid).grid |> Grid.all_anchor_squares
  end

  @doc """
  Returns `true` if the given coordinate points to a square on the board.
  """
  @spec valid_square?(pid, coord) :: boolean
  def valid_square?(pid, coord) do
    result =
      with {:ok, coord} <- parse_coord(coord),
           grid = get(pid).grid,
        do: Grid.valid_coord?(grid, coord)

    case result do
      {:error, _} -> false
      _ -> result
    end
  end

  # Converts a single letter representing a column into an integer that matches
  # the board's coordinate system. Returns `:error` on failure.
  @spec letter_to_col(String.t) :: pos_integer | :error
  defp letter_to_col(string) when byte_size(string) === 1 do
    normalized = String.downcase(string)
    [char] = normalized |> to_char_list

    char - ?a + 1
  end

  defp letter_to_col(_), do: :error

  # Reveal all the squares on a `board` for debugging.
  #
  # If passed a `pid`, it will store the revealed state of the board in the
  # given process and return `{:ok, revealed_board}`.
  #
  # If passed a `board`, it will return a new board with the revealed state.
  @doc false
  @spec __reveal__(pid | t) :: {:ok, t} | t
  def __reveal__(pid) when is_pid(pid) do
    Agent.get_and_update(pid, fn board ->
      new_board = __reveal__(board)
      {{:ok, new_board}, new_board}
    end)
  end

  def __reveal__(%LexibombServer.Board{} = board) do
    %{board | grid: Grid.__reveal__(board.grid)}
  end

  @doc false
  @spec __example__(pid) :: :ok
  def __example__(pid) do
    [
      %LexibombServer.Play{start: "8I",  direction: :down,   letters: ~W(E N T E R)},
      %LexibombServer.Play{start: "8H",  direction: :across, letters: ~W(B E)},
      %LexibombServer.Play{start: "8B",  direction: :down,   letters: ~W(G A V E)},
      %LexibombServer.Play{start: "9E",  direction: :down,   letters: ~W(M U S E S)},
      %LexibombServer.Play{start: "10B", direction: :across, letters: ~W(V I R U L e N T)},
      %LexibombServer.Play{start: "12I", direction: :across, letters: ~W(R E D)},
      %LexibombServer.Play{start: "11K", direction: :across, letters: ~W(L Y T H E)},
      %LexibombServer.Play{start: "8K",  direction: :down,   letters: ~W(C H I L D R E N)},
      %LexibombServer.Play{start: "9K",  direction: :across, letters: ~W(H E A R D)},
      %LexibombServer.Play{start: "6O",  direction: :down,   letters: ~W(B R I D L E S)},
      %LexibombServer.Play{start: "7L",  direction: :across, letters: ~W(T O U R)},
    ]
    |> Enum.each(&make_play(pid, &1))
  end
end


defimpl Inspect, for: LexibombServer.Board do
  alias LexibombServer.Board.{Grid, Square}
  alias LexibombServer.Utils

  @spec inspect(LexibombServer.Board.t, Keyword.t) :: String.t
  def inspect(board, _opts) do
    render(board.grid)
  end

  @spec render(nil | Grid.t) :: String.t
  defp render(nil), do: "#Board<[]>"
  defp render(grid) do
    indent = 2
    label_width = 3
    space_width = 4
    line_width =
      indent + label_width + (Grid.size(grid) * space_width) + 1

    board =
      grid
      |> render_into_list
      |> Stream.map(&String.rjust(&1, line_width))
      |> Enum.join("\n")

    """
    #Board<
    #{board}
    >
    """
    |> String.rstrip
  end

  @spec render_into_list(Grid.t) :: [String.t]
  defp render_into_list(grid) do
    size = Grid.size(grid)

    header = header(size - 2)
    top    = Utils.draw_grid_line(size, :top)
    middle = collect_rows(grid)
    bottom = Utils.draw_grid_line(size, :bottom)

    [header] ++ [top] ++ middle ++ [bottom]
  end

  @spec header(pos_integer) :: String.t
  defp header(size) do
    last_col = ?a + size - 1
    spacer = "   "
    offset = "      "

    Enum.to_list(?a .. last_col)
    |> List.to_string
    |> String.graphemes
    |> Enum.join(spacer)
    |> Kernel.<>(offset)
  end

  @spec collect_rows(Grid.t) :: [String.t]
  defp collect_rows(grid) do
    size = Grid.size(grid)
    grid_line = Utils.draw_grid_line(size, :middle)

    grid
    |> chunk_by_rows(size)
    |> Stream.map(&Utils.draw_segments/1)
    |> label_rows(size)
    |> Enum.intersperse(grid_line)
  end

  @spec chunk_by_rows(Grid.t, pos_integer) :: Enumerable.t
  defp chunk_by_rows(grid, count) do
    grid
    |> Enum.sort_by(fn {coord, _} -> coord end)
    |> Stream.map(fn {_, square} -> Square.__render_state__(square) end)
    |> Stream.chunk(count)
  end

  @spec label_rows(Enumerable.t, pos_integer) :: Enumerable.t
  defp label_rows(rows, grid_size) do
    rows
    |> Stream.with_index
    |> Stream.map(fn {row, index} ->
         label? = !Utils.first_or_last?(index, grid_size)
         label = if label?, do: Utils.zero_pad(index, 2), else: "  "

         "#{label} #{row}"
       end)
  end
end
