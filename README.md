<p align="center">
  <img src="assets/logo.png" alt="Quillpoint" width="160">
</p>

<h1 align="center">Quillpoint</h1>

<p align="center"><strong>A calm, keyboard-first task manager for macOS.</strong></p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" alt="Platform">
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="License">
</p>

Quillpoint keeps your work in plain, nestable lists you can fly through without
ever reaching for the mouse — type a task, hit Return for the next, Tab to nest
it under the last. It's a native SwiftUI app: fast, quiet, and built to stay out
of your way. And because losing a to-do list is its own small disaster, every
restore snapshots your current data first, so nothing you do is one click from
gone.

![Quillpoint showing the All Projects view grouped by priority](assets/screenshot.png)

## Why Quillpoint

- **Write, don't fill out forms.** Tasks are rich text — **bold**, *italic*, and
  links right in the title or notes. Paste from anywhere; formatting comes along.
- **Structure that bends to you.** Drag to reorder, drop one task onto another to
  nest it, drag a subtask out to promote it. Completed work quietly sinks to the
  bottom so the top of your list is always what's next.
- **Fingers on the keys.** Arrow keys, Return, and Tab/Shift+Tab move, create,
  and nest tasks without a single click. ⌘N for a new item, ⌘, for settings.
- **Two ways to look at it.** A focused, per-project list when you're heads-down,
  or an All Projects view grouped by project or priority when you're planning.
- **See what you got done.** A Report view lays out what you completed, day by
  day, over any date range you pick.
- **Reminders that reach you.** Attach a date to any task, pick a preset, and get
  a native notification with Mark Done and Snooze — plus an optional Upcoming
  view that lists every reminder by when it's due.
- **Yours to keep.** Full undo/redo, scheduled backups you can name and pin, and
  JSON export/import. Updates migrate your data safely — and if it ever won't
  open, a recovery screen restores it from a backup or JSON without touching
  what's there.

## Requirements

- macOS 15 or later
- Xcode 16 or later

## Getting Started

```bash
git clone https://github.com/Yegor689/Quillpoint.git
```

Open `TaskTracker.xcodeproj` in Xcode and run (⌘R). No dependencies, no setup —
pure SwiftUI and SwiftData.

## Architecture

The app is a SwiftUI `NavigationSplitView` over a SwiftData store. UI lives in
`Views/`, with `@Observable` stores (`TaskStore`, `ProjectStore`,
`BackupManager`, `ReminderManager`, `AppSettings`) handling mutations and side
effects. Backups snapshot the live store with SQLite's `VACUUM INTO` for a
consistent, self-contained copy (no `-wal`/`-shm` sidecars), and restore happens
in place so the window updates live. See
[docs/MODEL.md](docs/MODEL.md) for the data model and a view/manager breakdown.

## License

MIT
