# CodeTutor Project

CodeTutor is a read-only Emacs tutoring assistant for developers who want to learn while they code.

The package should behave like a senior/staff engineer pair programmer:

- guide the user through reasoning, architecture, testing, and tradeoffs
- teach underlying concepts while reviewing real work
- activate after file saves with a diff of what changed
- answer minibuffer prompts with current file and project context
- recommend the next best step on demand
- open in a right-side tray beside the editor buffer
- maintain durable architecture memory without editing project code

The tutor should not code for the user. It should avoid patches, full implementations, and replacement code. It can give compact illustrative examples, sketches, and testing/refactoring patterns when those samples help teach the underlying concept or API shape.

Initial backend support targets local `codex` and `pi` CLIs. Both must be configured in read-only ways.
