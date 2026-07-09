# Example: Building a Rust CLI Task Manager

This walkthrough shows Blue Lodge building a Rust project — a terminal task manager with file-based persistence. Demonstrates Rust scaffolding, iterative development, and the fix/test cycle.

---

## 1. Scaffold the project

```
$ lodge /init tasks rust
 ▸ Creating Rust project...
 ✓ Rust sandbox ready
 ✓ GEORGE.md initialized in .
 ✓ Project 'tasks' (Rust) created at /home/user/tasks
```

## 2. Describe the task

```
$ cd tasks
$ lodge "Build a CLI task manager. Commands: add <title>, list, done <id>, remove <id>.
  Store tasks in a tasks.json file. Use clap for CLI parsing.
  Each task has: id (u32), title (String), done (bool), created (String)."
```

## 3. Lodge plans

```
 ── Plan ────────────────────────────────────
   1. Add clap dependency to Cargo.toml
   2. Define Task struct and storage
   3. Implement add command
   4. Implement list command (with status indicators)
   5. Implement done and remove commands
   6. Add display formatting
   7. Test all commands
```

## 4. Generated project structure

```
tasks/
├── GEORGE.md
├── Cargo.toml
├── src/
│   └── main.rs
└── tasks.json       # Created at runtime
```

### Generated `Cargo.toml` additions:

```toml
[dependencies]
clap = { version = "4", features = ["derive"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
chrono = { version = "0.4", features = ["serde"], default-features = false }
```

### Generated `src/main.rs` (excerpt):

```rust
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

const TASKS_FILE: &str = "tasks.json";

#[derive(Parser)]
#[command(name = "tasks", about = "A simple task manager")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Add a new task
    Add { title: String },
    /// List all tasks
    List,
    /// Mark a task as done
    Done { id: u32 },
    /// Remove a task
    Remove { id: u32 },
}

#[derive(Serialize, Deserialize, Clone)]
struct Task {
    id: u32,
    title: String,
    done: bool,
    created: String,
}

#[derive(Serialize, Deserialize, Default)]
struct TaskStore {
    tasks: Vec<Task>,
    next_id: u32,
}

impl TaskStore {
    fn load() -> Self {
        fs::read_to_string(TASKS_FILE)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    fn save(&self) -> Result<(), Box<dyn std::error::Error>> {
        let json = serde_json::to_string_pretty(self)?;
        fs::write(TASKS_FILE, json)?;
        Ok(())
    }

    fn add(&mut self, title: String) -> &Task {
        let task = Task {
            id: self.next_id,
            title,
            done: false,
            created: chrono::Utc::now().format("%Y-%m-%d %H:%M").to_string(),
        };
        self.next_id += 1;
        self.tasks.push(task);
        self.tasks.last().unwrap()
    }
    // ...
}

fn main() {
    let cli = Cli::parse();
    let mut store = TaskStore::load();

    match cli.command {
        Commands::Add { title } => {
            let task = store.add(title);
            println!("✓ Added task #{}: {}", task.id, task.title);
        }
        Commands::List => {
            if store.tasks.is_empty() {
                println!("No tasks yet. Add one with: tasks add \"my task\"");
                return;
            }
            for task in &store.tasks {
                let marker = if task.done { "✓" } else { "○" };
                println!(" {} [{}] {} ({})", marker, task.id, task.title, task.created);
            }
            let done = store.tasks.iter().filter(|t| t.done).count();
            println!("\n {}/{} complete", done, store.tasks.len());
        }
        Commands::Done { id } => { /* ... */ }
        Commands::Remove { id } => { /* ... */ }
    }

    store.save().expect("Failed to save tasks");
}
```

## 5. Build and test

```
$ lodge /build
 ▸ Running: cargo build
   Compiling tasks v0.1.0
 ✓ Build succeeded

$ lodge /test
 ▸ Running: cargo test
   running 0 tests
 ✓ Tests passed
```

## 6. Manual testing cycle

```
$ cargo run -- add "Learn about closures in Rust"
✓ Added task #0: Learn about closures in Rust

$ cargo run -- add "Build a web scraper"
✓ Added task #1: Build a web scraper

$ cargo run -- list
 ○ [0] Learn about closures in Rust (2026-02-22 14:30)
 ○ [1] Build a web scraper (2026-02-22 14:30)

 0/2 complete

$ cargo run -- done 0
✓ Task #0 marked as done

$ cargo run -- list
 ✓ [0] Learn about closures in Rust (2026-02-22 14:30)
 ○ [1] Build a web scraper (2026-02-22 14:30)

 1/2 complete
```

## 7. Fix cycle — when things go wrong

If `cargo build` fails:

```
$ lodge /fix
 ▸ Running cargo check...
error[E0599]: no method named `format` found for struct `DateTime<Utc>`...

 ── Errors Found ────────────────────────────
 ...
 ◆ Planning fix...
 ▸ Step 1: Add chrono format feature to Cargo.toml
 ✓ Fixed! Build succeeded.
```

Lodge reads the compiler error, figures out the fix, and applies it — one step.

## 8. Add features iteratively

```
$ lodge "add a 'search' subcommand that filters tasks by title substring"
```

Lodge checks GEORGE.md, sees the existing structure, and adds just the new subcommand without rewriting the whole file.

## 9. Release build (optimized for mobile)

```
$ lodge /build release
 ▸ Running: cargo build --release
   Compiling tasks v0.1.0 (optimized)
 ✓ Build succeeded

$ ls -la target/release/tasks
-rwxr-xr-x 1 user user 1.2M Feb 22 15:00 target/release/tasks
```

The `Cargo.toml` includes mobile-optimized release settings: `lto = "thin"`, `strip = true`.

---

## Key Observations

- **Builds on ARM** — Rust cross-compiles cleanly; `cargo build` works in proot Ubuntu
- **Incremental builds** — After the initial compile, changes are fast (~5s)
- **Lodge remembers state** — GEORGE.md tracks which files exist, what the build command is, and what errors were encountered
- **`/fix` is powerful** — It runs `cargo check`, feeds errors to the LLM, and applies patches automatically
- **Release binary is small** — `strip = true` keeps the binary under 2MB

---

## Pro Tips for Longer Projects

- **Switch models mid-project** — Use `/models select primary qwen35-4b-think` if you want stronger reasoning during debugging, then switch back to a faster instruct model for boilerplate generation.
- **Ingest Rust docs** — `/ingest add ~/docs/rust-book.pdf` makes the Rust book searchable. Then ask: `What's the difference between &str and String?` and George pulls the relevant section.
- **Journal your progress** — `/journal write "Got the CLI parsing working, next: add SQLite persistence"` — George reads this next session and picks up where you left off.
- **Automate your workflow** — `/slash create build-test "Run /build, then /test, then /commit if tests pass"` chains your whole cycle into one command.
