import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const WaterSortApp());

const ink = Color(0xFF603813);
const muted = Color(0xFF9B7B5A);
const canvas = Color(0xFFFFF6E5);
const lavender = Color(0xFFD97706); // Premium amber accent

const waterColors = <Color>[
  Color(0xFFFF8DAB),
  Color(0xFF68C7E8),
  Color(0xFFFFC765),
  Color(0xFF8ED9B0),
  Color(0xFFAA91F5),
  Color(0xFFFF9B68),
  Color(0xFF58C7B7),
  Color(0xFFEB83D4),
];

const levelNames = [
  'Medium',
  'Medium',
  'Medium-Hard',
  'Hard',
  'Very Hard',
];

const levelDescriptions = [
  'Mostly simple mixing',
  'More mixed layers',
  'Colors mixed deeper into the tubes',
  'Harder arrangement, one empty tube',
  'Highly mixed arrangement, one empty tube',
];

const levelColors = [4, 5, 6, 7, 8];

const levelEmptyTubes = [2, 2, 2, 1, 1];

// ---------------------------------------------------------------------------
// Difficulty rules per level.
//
// "Transitions" = number of places where two neighbouring layers inside a tube
// have different colors (max 3 per tube). More transitions = more mixed.
// "Bottom mixed" = number of tubes whose two bottom layers differ, meaning the
// mixing reaches deep into the tube and not just the top.
// ---------------------------------------------------------------------------
const levelMinTransitions = [5, 9, 12, 17, 20];
const levelMaxTransitions = [8, 11, 99, 99, 99];
const levelMaxDistinct = [3, 3, 6, 6, 8]; // max different colors in one tube
const levelMinBottomMixed = [0, 1, 3, 5, 7];

typedef Puzzle = List<List<int>>;

// ---------------------------------------------------------------------------
// Shared puzzle logic (top-level so it can run in an isolate)
// ---------------------------------------------------------------------------

const int kCapacity = 4;

Puzzle copyPuzzle(Puzzle puzzle) =>
    puzzle.map((t) => List<int>.from(t)).toList();

bool isSolvedPuzzle(Puzzle puzzle) {
  for (final tube in puzzle) {
    if (tube.isEmpty) continue;
    if (tube.length != kCapacity) return false;
    if (tube.any((c) => c != tube.first)) return false;
  }
  return true;
}

bool canPourPuzzle(Puzzle p, int from, int to) {
  if (from == to) return false;
  if (p[from].isEmpty) return false;
  if (p[to].length >= kCapacity) return false;
  if (p[to].isEmpty) return true;
  return p[from].last == p[to].last;
}

// Tube order doesn't matter for solving, so sort to detect duplicate states.
String canonicalKey(Puzzle p) {
  final keys = p.map((t) => t.join(',')).toList()..sort();
  return keys.join('|');
}

bool _isUniform(List<int> t) => t.isNotEmpty && t.every((c) => c == t.first);

int _transitions(Puzzle p) {
  int total = 0;
  for (final t in p) {
    for (int i = 0; i < t.length - 1; i++) {
      if (t[i] != t[i + 1]) total++;
    }
  }
  return total;
}

int _bottomMixed(Puzzle p) {
  int total = 0;
  for (final t in p) {
    if (t.length >= 2 && t[0] != t[1]) total++;
  }
  return total;
}

int _maxDistinct(Puzzle p) {
  int best = 0;
  for (final t in p) {
    best = max(best, t.toSet().length);
  }
  return best;
}

bool _meetsDifficulty(Puzzle p, int levelIndex) {
  final t = _transitions(p);
  return t >= levelMinTransitions[levelIndex] &&
      t <= levelMaxTransitions[levelIndex] &&
      _maxDistinct(p) <= levelMaxDistinct[levelIndex] &&
      _bottomMixed(p) >= levelMinBottomMixed[levelIndex];
}

// Builds a board that matches the level's difficulty rules AND is verified
// solvable by the solver. Runs in a background isolate via compute().
Puzzle generateLevelPuzzle(int level) {
  final levelIndex = level - 1;
  final colorCount = levelColors[levelIndex];
  final emptyCount = levelEmptyTubes[levelIndex];
  final random = Random();

  Puzzle buildRandom() {
    final layers = <int>[];
    for (int c = 0; c < colorCount; c++) {
      for (int i = 0; i < kCapacity; i++) {
        layers.add(c);
      }
    }
    layers.shuffle(random);

    final tubes = <List<int>>[];
    for (int i = 0; i < colorCount; i++) {
      tubes.add(layers.sublist(i * kCapacity, (i + 1) * kCapacity));
    }
    for (int i = 0; i < emptyCount; i++) {
      tubes.add(<int>[]);
    }
    return tubes;
  }

  // Pass 1: match difficulty rules + must be solvable.
  for (int attempt = 0; attempt < 5000; attempt++) {
    final p = buildRandom();
    if (!_meetsDifficulty(p, levelIndex)) continue;
    if (_solve(p, 40000) == null) continue; // unsolvable or too hard to verify
    p.shuffle(random);
    return p;
  }

  // Pass 2 (fallback, very rare): relax difficulty, keep solvability.
  while (true) {
    final p = buildRandom();
    if (isSolvedPuzzle(p)) continue;
    if (_solve(p, 40000) == null) continue;
    p.shuffle(random);
    return p;
  }
}

// ---------------------------------------------------------------------------
// Solver (also runs in a background isolate via compute)
// ---------------------------------------------------------------------------

int _heuristic(Puzzle p) {
  int h = 0;
  for (final t in p) {
    if (t.isEmpty) continue;
    int run = 1;
    while (run < t.length && t[run] == t[0]) {
      run++;
    }
    h += t.length - run; // units sitting on top of a different color
  }
  return h;
}

class _Node {
  _Node(this.puzzle, this.parent, this.from, this.to, this.g);
  final Puzzle puzzle;
  final int parent;
  final int from;
  final int to;
  final int g;
}

class _MinHeap {
  final List<int> _prio = [];
  final List<int> _id = [];

  bool get isNotEmpty => _id.isNotEmpty;

  void add(int prio, int id) {
    _prio.add(prio);
    _id.add(id);
    int i = _id.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_prio[p] <= _prio[i]) break;
      _swap(i, p);
      i = p;
    }
  }

  int removeMin() {
    final top = _id[0];
    final lastP = _prio.removeLast();
    final lastI = _id.removeLast();
    if (_id.isNotEmpty) {
      _prio[0] = lastP;
      _id[0] = lastI;
      int i = 0;
      while (true) {
        final l = 2 * i + 1;
        final r = l + 1;
        int m = i;
        if (l < _id.length && _prio[l] < _prio[m]) m = l;
        if (r < _id.length && _prio[r] < _prio[m]) m = r;
        if (m == i) break;
        _swap(i, m);
        i = m;
      }
    }
    return top;
  }

  void _swap(int a, int b) {
    final tp = _prio[a];
    _prio[a] = _prio[b];
    _prio[b] = tp;
    final ti = _id[a];
    _id[a] = _id[b];
    _id[b] = ti;
  }
}

// Returns the first move [from, to] of a solution.
// Returns an empty list if already solved, or null if no solution was found
// within maxStates.
List<int>? _solve(Puzzle start, int maxStates) {
  if (isSolvedPuzzle(start)) return const <int>[];

  final nodes = <_Node>[_Node(copyPuzzle(start), -1, -1, -1, 0)];
  final visited = <String>{canonicalKey(start)};
  final heap = _MinHeap()..add(_heuristic(start) * 4, 0);

  while (heap.isNotEmpty && nodes.length < maxStates) {
    final index = heap.removeMin();
    final node = nodes[index];
    final cur = node.puzzle;

    if (isSolvedPuzzle(cur)) {
      int cursor = index;
      while (nodes[cursor].parent > 0) {
        cursor = nodes[cursor].parent;
      }
      return [nodes[cursor].from, nodes[cursor].to];
    }

    bool triedEmpty = false;

    for (int to = 0; to < cur.length; to++) {
      if (cur[to].isEmpty) {
        if (triedEmpty) continue; // all empty tubes are equivalent
        triedEmpty = true;
      }

      for (int from = 0; from < cur.length; from++) {
        if (!canPourPuzzle(cur, from, to)) continue;

        // Skip pointless moves.
        if (_isUniform(cur[from]) &&
            (cur[from].length == kCapacity || cur[to].isEmpty)) {
          continue;
        }

        final next = copyPuzzle(cur);
        next[to].add(next[from].removeLast());

        if (!visited.add(canonicalKey(next))) continue;

        nodes.add(_Node(next, index, from, to, node.g + 1));
        heap.add(_heuristic(next) * 4 + node.g + 1, nodes.length - 1);
      }
    }
  }

  return null;
}

// Used by the Hint button through compute().
List<int>? solveFirstMove(Puzzle start) {
  final result = _solve(start, 400000);
  if (result == null || result.isEmpty) return null;
  return result;
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

class WaterSortApp extends StatelessWidget {
  const WaterSortApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WaterSort AI',
      theme: ThemeData(
        scaffoldBackgroundColor: canvas,
        colorScheme: ColorScheme.fromSeed(seedColor: lavender),
        useMaterial3: true,
      ),
      home: const GameScreen(),
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  static const int capacity = kCapacity;

  int _level = 1;
  int _unlockedLevel = 1;
  int _moves = 0;
  int _generation = 0; // guards against overlapping level generations

  Puzzle _tubes = [];
  Puzzle _initial = [];
  final List<Puzzle> _history = [];

  int? _selected;
  bool _busy = false;
  bool _won = false;

  String _status = 'Select a tube to start pouring.';
  List<int>? _hintMove;

  @override
  void initState() {
    super.initState();
    _loadProgress();
    _newGame(1);
  }

  Future<void> _loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final savedLevel = prefs.getInt('watersort_unlocked_level') ?? 1;
    setState(() {
      _unlockedLevel = savedLevel.clamp(1, 5);
    });
  }

  Future<void> _saveProgress() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('watersort_unlocked_level', _unlockedLevel);
  }

  Puzzle _copyPuzzle(Puzzle puzzle) => copyPuzzle(puzzle);

  // Generates a verified-solvable board that matches the level's difficulty.
  Future<void> _newGame(int level) async {
    final safeLevel = level.clamp(1, 5);
    final token = ++_generation;

    setState(() {
      _level = safeLevel;
      _tubes = [];
      _initial = [];
      _history.clear();
      _moves = 0;
      _selected = null;
      _hintMove = null;
      _busy = true;
      _won = false;
      _status = 'Preparing a solvable level...';
    });

    final puzzle = await compute(generateLevelPuzzle, safeLevel);

    if (!mounted || token != _generation) return;

    setState(() {
      _tubes = _copyPuzzle(puzzle);
      _initial = _copyPuzzle(puzzle);
      _busy = false;
      _status = 'Select a tube to start pouring.';
    });
  }

  bool _isSolved(Puzzle puzzle) => isSolvedPuzzle(puzzle);

  // Empty tube accepts any color, otherwise the top colors must match.
  bool _canManualPour(Puzzle puzzle, int from, int to) =>
      canPourPuzzle(puzzle, from, to);

  void _pour(Puzzle puzzle, int from, int to) {
    if (puzzle[from].isNotEmpty && puzzle[to].length < capacity) {
      puzzle[to].add(puzzle[from].removeLast());
    }
  }

  void _selectTube(int index) {
    if (_busy || _won) return;

    bool justWon = false;

    setState(() {
      _hintMove = null;

      if (_selected == null) {
        if (_tubes[index].isEmpty) {
          _status = 'Choose a tube containing water.';
        } else {
          _selected = index;
          _status = 'Now choose any tube with available space.';
        }
        return;
      }

      if (_selected == index) {
        _selected = null;
        _status = 'Selection cancelled.';
        return;
      }

      final from = _selected!;

      if (!_canManualPour(_tubes, from, index)) {
        if (_tubes[index].isNotEmpty) {
          _selected = index;
          _status = 'Tube selected as the new source.';
        } else {
          _status = 'Cannot pour there.';
        }
        return;
      }

      _history.add(_copyPuzzle(_tubes));
      _pour(_tubes, from, index);
      _moves++;
      _selected = null;

      if (_isSolved(_tubes)) {
        _won = true;
        justWon = true;
        _status = 'Level complete!';
      } else {
        _status = 'Good move! Keep sorting the colors.';
      }
    });

    if (justWon) _handleWin();
  }

  Future<void> _handleWin() async {
    if (_level < 5 && _level >= _unlockedLevel) {
      setState(() => _unlockedLevel = _level + 1);
      await _saveProgress();
    }

    if (!mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: const Text('Level Complete! 🎉'),
        content: Text(
          'You completed Level $_level in $_moves moves.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {});
            },
            child: const Text('Stay Here'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              if (_level < 5) {
                _newGame(_level + 1);
              } else {
                _showLevels();
              }
            },
            child: Text(_level < 5 ? 'Next Level' : 'All Levels'),
          ),
        ],
      ),
    );
  }

  void _undo() {
    if (_history.isEmpty || _busy) return;

    setState(() {
      _tubes = _history.removeLast();
      _moves = max(0, _moves - 1);
      _selected = null;
      _hintMove = null;
      _won = false;
      _status = 'Last move undone.';
    });
  }

  void _reset() {
    if (_busy) return;

    setState(() {
      _tubes = _copyPuzzle(_initial);
      _history.clear();
      _moves = 0;
      _selected = null;
      _hintMove = null;
      _busy = false;
      _won = false;
      _status = 'Level reset. Try again!';
    });
  }

  Future<void> _getHint() async {
    if (_busy || _won || _tubes.isEmpty) return;

    final start = _copyPuzzle(_tubes);
    final startKey = canonicalKey(start);

    setState(() {
      _busy = true;
      _hintMove = null;
      _selected = null;
      _status = 'AI is searching for a valid move...';
    });

    // Runs in a background isolate so the UI never freezes.
    final move = await compute(solveFirstMove, start);

    if (!mounted) return;

    setState(() {
      _busy = false;

      if (canonicalKey(_tubes) != startKey) {
        _status = 'Board changed. Try Hint again.';
      } else if (move == null) {
        _status = 'No solution from this position. Try Undo or Reset.';
      } else {
        _hintMove = move;
        _status =
            'Hint: pour from Tube ${move[0] + 1} to Tube ${move[1] + 1}.';
      }
    });
  }

  void _showLevels() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 26),
          decoration: const BoxDecoration(
            color: const Color(0xFFFFFBF2),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 42,
                    height: 5,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8D5B8),
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Choose a Level',
                    style: TextStyle(
                      color: ink,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ...List.generate(5, (index) {
                    final number = index + 1;
                    final unlocked = number <= _unlockedLevel;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(17),
                        onTap: unlocked
                            ? () {
                                Navigator.pop(context);
                                _newGame(number);
                              }
                            : null,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: unlocked
                                ? const Color(0xFFFFEBC7)
                                : const Color(0xFFF6EFE3),
                            borderRadius: BorderRadius.circular(17),
                            border: Border.all(
                              color: unlocked
                                  ? const Color(0xFFF0D4A7)
                                  : const Color(0xFFE9DCC9),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: unlocked
                                      ? lavender.withOpacity(0.13)
                                      : const Color(0xFFEFE2CF),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Icon(
                                  unlocked ? Icons.water_drop : Icons.lock,
                                  color: unlocked ? lavender : muted,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Level $number',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: ink,
                                        fontSize: 15,
                                      ),
                                    ),
                                    Text(
                                      levelDescriptions[index],
                                      style: const TextStyle(
                                        color: ink,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      '${levelNames[index]} • '
                                      '${levelColors[index]} colors • '
                                      '${levelColors[index] + levelEmptyTubes[index]} tubes • '
                                      '${levelEmptyTubes[index]} empty',
                                      style: const TextStyle(
                                        color: muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                unlocked
                                    ? Icons.arrow_forward_ios_rounded
                                    : Icons.lock_outline,
                                size: 17,
                                color: unlocked ? lavender : muted,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hint = _hintMove;
    final emptyCount = levelEmptyTubes[_level - 1];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: lavender.withOpacity(0.13),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: const Icon(
                      Icons.water_drop_rounded,
                      color: lavender,
                      size: 25,
                    ),
                  ),
                  const SizedBox(width: 11),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'WaterSort AI',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                            color: ink,
                          ),
                        ),
                        Text(
                          'Sort the colors. Clear the tubes.',
                          style: TextStyle(color: muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Choose level',
                    onPressed: _showLevels,
                    icon: const Icon(Icons.grid_view_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Container(
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFBBF24), Color(0xFFD97706)],
                  ),
                  borderRadius: BorderRadius.circular(23),
                  boxShadow: [
                    BoxShadow(
                      color: lavender.withOpacity(0.22),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'LEVEL $_level  •  ${levelNames[_level - 1].toUpperCase()}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              letterSpacing: 1,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            levelDescriptions[_level - 1],
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${levelColors[_level - 1]} colors • '
                            '$emptyCount empty ${emptyCount == 1 ? 'tube' : 'tubes'}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.auto_awesome_rounded,
                      color: Colors.white,
                      size: 40,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      icon: Icons.swap_vert_rounded,
                      label: 'MOVES',
                      value: '$_moves',
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.color_lens_outlined,
                      label: 'COLORS',
                      value: '${levelColors[_level - 1]}',
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.emoji_events_outlined,
                      label: 'LEVEL',
                      value: '$_level/5',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = _tubes.length <= 6
                      ? 3
                      : (_tubes.length <= 8 ? 4 : 5);
                  final tubeWidth =
                      min(62.0, (constraints.maxWidth - 44) / columns - 10);
                  final tubeHeight = min(190.0, constraints.maxHeight * 0.42);

                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 13,
                      runSpacing: 23,
                      children: List.generate(_tubes.length, (index) {
                        final isHintSource = hint != null && hint[0] == index;
                        final isHintTarget = hint != null && hint[1] == index;

                        return GestureDetector(
                          onTap: () => _selectTube(index),
                          child: SizedBox(
                            width: tubeWidth,
                            child: Column(
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  transform: Matrix4.translationValues(
                                    0,
                                    _selected == index ? -8 : 0,
                                    0,
                                  ),
                                  child: _Tube(
                                    colors: _tubes[index],
                                    capacity: capacity,
                                    selected: _selected == index ||
                                        isHintSource ||
                                        isHintTarget,
                                    width: tubeWidth,
                                    height: tubeHeight,
                                    hintSource: isHintSource,
                                    hintTarget: isHintTarget,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  'Tube ${index + 1}',
                                  style: TextStyle(
                                    color: isHintSource || isHintTarget
                                        ? lavender
                                        : muted,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ),
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
              decoration: const BoxDecoration(
                color: const Color(0xFFFFFBF2),
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x0C26334A),
                    blurRadius: 15,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(
                        _busy
                            ? Icons.hourglass_top_rounded
                            : Icons.lightbulb_outline_rounded,
                        color: lavender,
                        size: 19,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status,
                          style: const TextStyle(
                            color: ink,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (_busy)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 13),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _history.isEmpty || _busy ? null : _undo,
                          icon: const Icon(Icons.undo_rounded, size: 18),
                          label: const Text('Undo'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _reset,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Reset'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy || _won ? null : _getHint,
                          icon: const Icon(Icons.auto_awesome, size: 17),
                          label: const Text('Hint'),
                          style: FilledButton.styleFrom(
                            backgroundColor: lavender,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: _showLevels,
                    icon: const Icon(Icons.layers_outlined, size: 17),
                    label: const Text('All Levels'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: const Color(0xFFE9DCC9)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: lavender),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 8,
                    letterSpacing: 0.6,
                    color: muted,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 17,
                    color: ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tube extends StatelessWidget {
  const _Tube({
    required this.colors,
    required this.capacity,
    required this.selected,
    required this.width,
    required this.height,
    required this.hintSource,
    required this.hintTarget,
  });

  final List<int> colors;
  final int capacity;
  final bool selected;
  final double width;
  final double height;
  final bool hintSource;
  final bool hintTarget;

  @override
  Widget build(BuildContext context) {
    final highlight = hintSource
        ? const Color(0xFFF59E0B)
        : hintTarget
            ? const Color(0xFF2D9B78)
            : lavender;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: width,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(15),
          bottom: Radius.circular(24),
        ),
        color: Colors.white.withOpacity(0.25),
        border: Border.all(
          color: selected
              ? highlight
              : const Color(0xFFAAB8CC).withOpacity(0.8),
          width: selected ? 3 : 2,
        ),
        boxShadow: [
          BoxShadow(
            color: selected
                ? highlight.withOpacity(0.24)
                : const Color(0x1826334A),
            blurRadius: selected ? 14 : 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(9),
          bottom: Radius.circular(19),
        ),
        child: Stack(
          children: [
            Column(
              children: List.generate(capacity, (displayIndex) {
                final layerIndex = capacity - 1 - displayIndex;
                final filled = layerIndex < colors.length;

                if (!filled) {
                  return const Expanded(child: SizedBox.expand());
                }

                final color = waterColors[colors[layerIndex]];
                final isTopLayer = layerIndex == colors.length - 1;

                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 0.5),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 260),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Color.lerp(color, Colors.white, 0.23)!,
                            color,
                            Color.lerp(color, Colors.black, 0.07)!,
                          ],
                          stops: const [0, 0.4, 1],
                        ),
                        borderRadius: BorderRadius.vertical(
                          top: isTopLayer
                              ? const Radius.circular(12)
                              : const Radius.circular(3),
                          bottom: const Radius.circular(5),
                        ),
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            left: 4,
                            top: 3,
                            bottom: 3,
                            child: Container(
                              width: 2,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.32),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          if (isTopLayer)
                            Positioned(
                              left: 1,
                              right: 1,
                              top: 1,
                              child: Container(
                                height: 5,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.white.withOpacity(0.68),
                                      Colors.white.withOpacity(0.08),
                                      Colors.white.withOpacity(0.42),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
            Positioned(
              left: 3,
              top: 7,
              bottom: 9,
              child: IgnorePointer(
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withOpacity(0.85),
                        Colors.white.withOpacity(0.18),
                        Colors.white.withOpacity(0.60),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 3,
              top: 12,
              bottom: 15,
              child: IgnorePointer(
                child: Container(
                  width: 1.5,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.48),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}