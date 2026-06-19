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

Initial backend support targets local `codex` and `pi` CLIs. Both must be configured in read-only ways. A remote Fireworks AI backend (OpenAI-compatible HTTP API over `curl`) is also supported for users without a local CLI; because it sends gathered context off the machine, it is never selected automatically and must be chosen explicitly.

The Fireworks backend runs an agentic loop: rather than pre-packing all context into one prompt, it exposes read-only, project-root-sandboxed tools (`read_file`, `list_directory`, `read_project_context`, `read_current_file`, `project_symbol_table`, `search_project`) and lets the model pull the context it needs. The project symbol table is built with tree-sitter and cached per session. Token usage and cost are accumulated across the loop and reported in the minibuffer. The read-only, no-write posture is preserved end to end.

CodeTutor also has a spec development mode for starting features. An Emacs command names a new spec, creates `spec/<slug>.md` from a teaching template, and opens a two-pane workbench (spec on top, tutor below) with a proactive interview. It is teach-only: the tutor co-develops the spec by interviewing and critiquing — never writing the spec body — and then teaches how to build the feature against that spec. The active spec is the throughline from idea to implementation; saving a spec file teaches spec-writing, while saving code with a spec active teaches implementation against it. The spec document is the source of truth (sections are parsed with regex on each request), so the only added state is a single in-session active-spec pointer.

For building without a spec, there is a scratch (thoughts) buffer: a freeform, ephemeral, session-persistent buffer for notes and questions while implementing, opened by a command, submitted to the tutor on save (teach-only), and cleared on demand. The scratch buffer and any open spec documents are "pinned" — inserted as distinct labeled sections into every prompt (both the one-shot and Fireworks agentic builders) while they have content, so the user's current thinking and working spec are always present rather than buried as generic context. Open specs are pinned with their live, unsaved buffer text. Pinned scratch content is inline-only (it has no file to fetch) and capped.
