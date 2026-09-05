# AGENTS.md
A markdown reader TUI written in Zig.

## Verifications
Make sure to run all after each change:
- `zig fmt .`
- `zig build test`

## Error handling
- Make sure to do proper error handling and free resources
  - Ensure to use `errdefer` to deinit allocated stuff in case of errors

## UI
- Make sure to keep UI always responsive and don't do any blocking work on the main thread
- Do things lazily and try avoiding allocating memory dynamically
  - For example don't try to parse a huge file at once, just process visible parts

## Testing
- Only test behaviours, do not unnecessary tests

## Style
- Keep regular imports at the end of the file just before tests, and keep test-only imports at the very end of the file
  - Keep all testing utils after `test` blocks just before test-only imports
- Import repeated functions or modules, like import `std.mem`, `std.testing`, `std.Io`, or `std.debug.assert` instead of fully qualifying
- For struct-style files, like `Document.zig`, keep the struct at top-level
  - `const Document = @import("Document.zig")` instead of `@import("Document.zig").Document`
- Don't add unnecessary comments, only add comments if there is something unintuitive
  - You can document top-level structs but keep those super concise
- Don't use `–` or `—` in regular text, use `-` if needed or avoid it completely
