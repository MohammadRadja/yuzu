# Test instructions

Tests use the direct runner in `Tests/YuzuTests.swift` and compile with app sources through Brisk. Keep test names behavior-focused, isolate filesystem fixtures in unique temporary directories, clean fixtures with `defer`, and cover edge cases and regressions. Update expected counts deliberately when formats or tools change. Do not require network or user data.
