# Changelog

## 0.2.0 (2026-10-22)

### Breaking changes

- Checks moved out of Credo's namespace: `Credo.Checks.Readability.ComplexElseClauses`
  is now `Smell.Check.Readability.ComplexElseClauses`. Update your `.credo.exs`.

### Added

- `Smell` is now a working Credo plugin: `plugins: [{Smell, []}]` enables every check.
- `Smell.checks/0` lists every check, for configs with an explicit `enabled` list.
- New check: `Smell.Check.Warning.NamespaceTrespassing`.
- New check: `Smell.Check.Design.AppConfigInLibrary`.
- New check: `Smell.Check.Design.UseInsteadOfImport`.
- New check: `Smell.Check.Warning.NonAssertivePatternMatching`.
- `ComplexElseClauses`: new `max_else_clauses` param (default `1`) and a link to the
  documentation (`mix credo explain`).

### Changed

- `credo` is now a regular dependency, so the checks are available to projects that
  install Smell from Hex.
- `ComplexElseClauses` only reports `with` expressions with two or more `<-` clauses.
  With a single `<-` clause the source of the error is unambiguous, and Credo's
  `WithSingleClause` already reports that case.
- `ComplexElseClauses` reports the issue on the `with` line instead of the last
  `else` clause.

### Fixed

- `ComplexElseClauses` no longer crashes on code that uses `with` as a variable or
  function name.

## 0.1.1

- First release with `ComplexElseClauses`.
