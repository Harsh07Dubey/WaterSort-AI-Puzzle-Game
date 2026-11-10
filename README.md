# WaterSort AI — Flutter starter

This starter contains a portrait Water Sort game with a clean pastel design, manual pouring, undo/reset, AI Hint and BFS-powered AI Solve. It uses Flutter/Dart only and has no third-party runtime dependencies.

## Run it

1. Install Flutter and Android Studio, and make sure `flutter doctor` reports a usable device/emulator.
2. Extract this ZIP.
3. Open the `watersort_ai` folder in VS Code.
4. In the terminal, run:

   ```bash
   flutter pub get
   flutter run
   ```

If you already have a Flutter project, you can also copy `lib/main.dart` into your existing project's `lib/main.dart` and run `flutter pub get`.

## What is implemented

- Pastel/light mobile UI
- Stylized glass tubes and colored layers
- Tap-to-pour gameplay and valid-move checks
- Move counter, undo, reset, new puzzle
- BFS solver, AI Hint and animated AI Solve
- Puzzles are created by scrambling a solved board using legal moves

## Learning notes

- A tube is represented as a `List<int>` ordered **bottom to top**.
- The complete board is a `List<List<int>>`.
- `_canPour` checks the rules before a move.
- `_pour` transfers the entire top contiguous group of the same color, as in common Water Sort rules.
- `_bfs` uses a queue to explore states by move count and a parent map to reconstruct the solution.
- The initial scramble is deliberately short to keep the starter responsive. For larger levels, move BFS to an isolate and/or use A* with a carefully tested heuristic.

## Suggested next improvements

1. Test on the target phone/emulator and adjust tube sizing for your display.
2. Add a dedicated level-selection screen.
3. Add A* and collect actual BFS/A* benchmarks.
4. Add a small test suite for move legality and solved-state detection.
5. Add accessibility labels and persist unlocked levels.
