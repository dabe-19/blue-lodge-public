# George Gym — Validation Workouts & RLHF Alignment Reference

> **Purpose**: Repeatable prompt→trace→result test cases for validating George's
> agent loop behavior on 2-4B parameter models. Each workout specifies the exact
> user prompt, expected honeydew decomposition, ideal milestone trace, and pass/fail
> criteria. Future: forms the seed alignment dataset for RLHF fine-tuning.

---

## How to Use

1. Run George with the model under test (e.g., `qwen35-4b-think`, `gemma4-e4b-inst`)
2. Enter the **User Prompt** verbatim
3. Compare the actual trace against the **Expected Trace**
4. Score using the **Pass/Fail Criteria**
5. Log results in the **Run Log** section at the bottom

### Scoring Key

| Grade | Meaning |
|-------|---------|
| **P** | Pass — trace matches expected flow, correct output |
| **D** | Deviated — reached correct output but via wrong route (e.g., extra web searches) |
| **L** | Loop — got stuck repeating a command or milestone |
| **F** | Fail — wrong output, crashed, or never completed |

---

## Workout 1: Rust FizzBuzz with Build Verification

**Difficulty**: Easy  
**Tests**: Honeydew decomposition, /init routing, /write with `\\n` escapes, /build dispatch, pre-route accuracy  
**Model stress**: Generating syntactically correct Rust across `\\n`-delimited single-line output

### User Prompt

```
Create a Rust project called fizzbuzz that prints fizzbuzz from 1 to 100, then build it.
```

### Expected Honeydew

```
1. [ ] Create the Rust project and implement FizzBuzz logic
2. [ ] Build the project and verify compilation
```

> Acceptable: 2-3 items. Red flag if >4 items (over-decomposition) or if items
> mention specific commands like "/write" or "/build" (tool leakage).

### Expected Trace

```
── Honeydew List
  1. [ ] Create the Rust project and implement FizzBuzz logic
  2. [ ] Build the project and verify compilation

── Milestone 1: Use /init to scaffold a Rust project named fizzbuzz
  [router]     /init (pre-routed)
  [specialist] /init fizzbuzz rust
  [output]     (exit 0 — project scaffolded, Cargo.toml + src/main.rs created)
  [eval-p1]    COMPLETE
  [eval-hd]    UNSATISFIED — project created but FizzBuzz logic not implemented

── Milestone 2: Use /write to implement FizzBuzz logic in src/main.rs
  [router]     /write (pre-routed)
  [specialist] /write fizzbuzz/src/main.rs fn main() {\n    for i in 1..=100 {\n        if i % 15 == 0 {\n            println!("FizzBuzz");\n        } else if i % 3 == 0 {\n            println!("Fizz");\n        } else if i % 5 == 0 {\n            println!("Buzz");\n        } else {\n            println!("{}", i);\n        }\n    }\n}
  [output]     (exit 0 — file written)
  [eval-p1]    COMPLETE
  [eval-hd]    SATISFIED — item #1 done (scaffold + code)

── Milestone 3: Use /build to compile the project
  [router]     /build (pre-routed)
  [specialist] /build
  [output]     (exit 0 — cargo build succeeds)
  [eval-p1]    COMPLETE
  [eval-hd]    SATISFIED — item #2 done

── Task complete.
```

### Pass/Fail Criteria

| # | Criterion | Required |
|---|-----------|----------|
| 1 | Honeydew has 2-3 items, no tool names in task text | Yes |
| 2 | /init fizzbuzz rust is the first command dispatched | Yes |
| 3 | /write produces valid Rust with correct FizzBuzz logic (% 3, % 5, % 15) | Yes |
| 4 | `\\n` escapes used for newlines (not literal multiline in specialist output) | Yes |
| 5 | /build runs and `cargo build` exits 0 | Yes |
| 6 | Total milestones ≤ 5 | Yes |
| 7 | No /web search or /recall (pure code generation — no research needed) | Yes |

### Common Failure Modes (2-4B)

- **FizzBuzz order bug**: Checks `% 3` before `% 15`, printing "Fizz" instead of "FizzBuzz" for multiples of 15. Indicates weak code reasoning.
- **Escape mangling**: Generates `\n` without the second backslash, or emits raw newlines that break single-line specialist parsing.
- **Over-decomposition**: 5+ honeydew items like "Create Cargo.toml", "Create src directory", "Write main.rs", "Add FizzBuzz function", "Build project" — wastes milestones.
- **Unnecessary /web search**: Model searches "how to write FizzBuzz in Rust" instead of generating from knowledge.

---

## Workout 2: Python Script with File I/O and Error Handling

**Difficulty**: Medium  
**Tests**: Multi-file /write, Python knowledge, /build or /test routing for validation, strategist sequencing  
**Model stress**: Generating a complete Python script with try/except, file I/O, and CSV formatting in `\\n` single-line format

### User Prompt

```
Write a Python script called csv_stats.py that reads a CSV file from a command-line argument, calculates the mean and standard deviation of a numeric column specified as a second argument, and prints the results. Handle the case where the file doesn't exist or the column name is invalid. Test it by creating a sample CSV and running the script.
```

### Expected Honeydew

```
1. [ ] Create the Python script with CSV parsing, statistics, and error handling
2. [ ] Create a sample CSV file for testing
3. [ ] Run the script against the sample data and verify output
```

> Acceptable: 2-4 items. Red flag if it decomposes error handling into its own
> item or creates separate items for "import libraries" and "parse arguments."

### Expected Trace

```
── Honeydew List
  1. [ ] Create the Python script with CSV parsing, statistics, and error handling
  2. [ ] Create a sample CSV file for testing
  3. [ ] Run the script against the sample data and verify output

── Milestone 1: Use /write to create csv_stats.py with argument parsing, CSV reading, and statistics
  [router]     /write (pre-routed)
  [specialist] /write csv_stats.py import csv\nimport sys\nimport math\n\ndef main():\n    if len(sys.argv) != 3:\n        print("Usage: csv_stats.py <file> <column>")\n        sys.exit(1)\n    filepath = sys.argv[1]\n    column = sys.argv[2]\n    try:\n        with open(filepath, newline='') as f:\n            reader = csv.DictReader(f)\n            values = []\n            for row in reader:\n                if column not in row:\n                    print(f"Error: column '{column}' not found")\n                    sys.exit(1)\n                values.append(float(row[column]))\n    except FileNotFoundError:\n        print(f"Error: file '{filepath}' not found")\n        sys.exit(1)\n    except ValueError:\n        print(f"Error: non-numeric data in column '{column}'")\n        sys.exit(1)\n    n = len(values)\n    mean = sum(values) / n\n    variance = sum((x - mean) ** 2 for x in values) / n\n    std = math.sqrt(variance)\n    print(f"Mean: {mean:.4f}")\n    print(f"Std Dev: {std:.4f}")\n\nif __name__ == '__main__':\n    main()
  [output]     (exit 0 — file written)
  [eval-p1]    COMPLETE
  [eval-hd]    SATISFIED — item #1

── Milestone 2: Use /write to create a sample CSV file
  [router]     /write (pre-routed)
  [specialist] /write sample.csv name,score,grade\nAlice,85,B\nBob,92,A\nCharlie,78,C\nDiana,95,A\nEve,88,B
  [output]     (exit 0 — file written)
  [eval-p1]    COMPLETE
  [eval-hd]    SATISFIED — item #2

── Milestone 3: Run the script against sample data using bash
  [router]     bash (or /sandbox run)
  [specialist] python3 csv_stats.py sample.csv score
  [output]     Mean: 87.6000\nStd Dev: 5.9330
  [eval-p1]    COMPLETE
  [eval-hd]    SATISFIED — item #3

── Task complete.
```

### Pass/Fail Criteria

| # | Criterion | Required |
|---|-----------|----------|
| 1 | Script uses `csv.DictReader` or equivalent (not raw string splitting) | Yes |
| 2 | FileNotFoundError and column-not-found cases handled with user-facing message | Yes |
| 3 | Math is correct (mean + std dev with population formula or sample — either acceptable) | Yes |
| 4 | Sample CSV is valid with a numeric column | Yes |
| 5 | Script is executed against sample data with correct column name | Yes |
| 6 | No /web search (standard library — no research needed) | Yes |
| 7 | Total milestones ≤ 6 | Yes |
| 8 | Strategist correctly sequences: write script → write data → run test | Yes |

### Common Failure Modes (2-4B)

- **Import hallucination**: Uses `import statistics` then calls `statistics.mean()` but forgets to collect values into a list, or imports `pandas` (overkill, may not be installed).
- **Column validation miss**: Doesn't check if column exists in CSV headers, crashes with KeyError.
- **Escape disaster**: Long scripts in `\\n` format break down — model loses track of indentation or forgets closing parens/brackets mid-stream.
- **Routing confusion**: Model tries to use `/test` (which looks for pytest/cargo frameworks) instead of `bash python3 csv_stats.py ...` for ad-hoc execution.
- **Honeydew over-split**: Creates 5+ items like "Parse command line arguments", "Implement CSV reading", "Calculate statistics", "Add error handling", "Create test file", "Run test".

---

## Workout 3: Multi-Step Research + Code Generation (Web → Write → Build)

**Difficulty**: Hard  
**Tests**: Research→delivery gate, web search/fetch pipeline, code generation from gathered data, /write integration, strategist command-family limits  
**Model stress**: Synthesizing web research into working code, transitioning from research to delivery phase

### User Prompt

```
Find the current top 5 most mass-produced programming languages and write a Rust CLI tool that prints them in a formatted table with their rank and TIOBE index percentage. Build it.
```

### Expected Honeydew

```
1. [ ] Research current TIOBE index rankings for top programming languages
2. [ ] Create a Rust project that displays the top 5 languages in a formatted table
3. [ ] Build and verify the project compiles
```

> Acceptable: 2-4 items. The research phase and code phase must be separate items.
> Red flag if code generation is attempted without any research milestone first.

### Expected Trace

```
── Honeydew List
  1. [ ] Research current TIOBE index rankings for top programming languages
  2. [ ] Create a Rust project that displays the top 5 languages in a formatted table
  3. [ ] Build and verify the project compiles

── Milestone 1: Use /web search to find current TIOBE index top programming languages
  [router]     /web (pre-routed)
  [specialist] /web search TIOBE index top programming languages 2026
  [output]     (exit 0 — search results with URLs)
  [eval-p1]    COMPLETE
  [eval-hd]    UNSATISFIED — need actual percentages, not just search links

── Milestone 2: Use /web fetch to get TIOBE index data from a result page
  [router]     /web (pre-routed)
  [specialist] /web fetch https://www.tiobe.com/tiobe-index/
  [output]     (exit 0 — page content with language rankings)
       [web condenser] Python 23.08%, C++ 11.51%, Java 10.34%, C 9.73%, JavaScript 4.28% ...
  [eval-p1]    COMPLETE
  [eval-hd]    SATISFIED — item #1 (concrete data gathered)

── RESEARCH→DELIVERY GATE triggers (2 consecutive research milestones)

── Milestone 3: Use /init to scaffold the Rust project
  [router]     /init (pre-routed)
  [specialist] /init tiobe_table rust
  [output]     (exit 0 — scaffolded)
  [eval-p1]    COMPLETE
  [eval-hd]    UNSATISFIED — code not written yet

── Milestone 4: Use /write to implement the table display in src/main.rs
  [router]     /write (pre-routed)
  [specialist] /write tiobe_table/src/main.rs fn main() {\n    let languages = [\n        ("Python", 23.08),\n        ("C++", 11.51),\n        ("Java", 10.34),\n        ("C", 9.73),\n        ("JavaScript", 4.28),\n    ];\n    println!("{:<6} {:<15} {:>8}", "Rank", "Language", "TIOBE %");\n    println!("{}", "-".repeat(31));\n    for (i, (lang, pct)) in languages.iter().enumerate() {\n        println!("{:<6} {:<15} {:>7.2}%", i + 1, lang, pct);\n    }\n}
  [output]     (exit 0 — file written)
  [eval-p1]    COMPLETE
  [eval-hd]    SATISFIED — item #2

── Milestone 5: Use /build to compile the project
  [router]     /build (pre-routed)
  [specialist] /build
  [output]     (exit 0 — cargo build succeeds)
  [eval-p1]    COMPLETE
  [eval-hd]    SATISFIED — item #3

── Task complete.
```

### Pass/Fail Criteria

| # | Criterion | Required |
|---|-----------|----------|
| 1 | At least 1 /web search + 1 /web fetch before code generation starts | Yes |
| 2 | Research data (language names + percentages) appears in the code | Yes |
| 3 | Data reflects actual web research, not hallucinated percentages | Preferred |
| 4 | Research→delivery gate fires (≤3 research milestones before delivery) | Yes |
| 5 | /init creates a Rust project before /write | Yes |
| 6 | Generated Rust code compiles with `cargo build` | Yes |
| 7 | Table formatting uses padding/alignment (not raw `println!` with spaces) | Preferred |
| 8 | Total milestones ≤ 8 | Yes |
| 9 | No /web search loop (≤2 searches before fetching) | Yes |

### Common Failure Modes (2-4B)

- **Research skip**: Model generates code with hallucinated TIOBE percentages from training data instead of searching the web. Evaluator must not mark this SATISFIED if no /web search occurred.
- **Web search loop**: 3+ consecutive `/web search` with slightly different queries, never transitioning to `/web fetch`. The web-search interlock should catch this.
- **Data rot**: Model uses data from 2023 training cutoff (Python/C/Java/C++/C#) instead of current 2026 results.
- **Pre-route lock**: Strategist writes "Use /web to research TIOBE data" for both search AND fetch milestones. Pre-route extracts `/web` both times — this is correct behavior but may confuse models that want different wording.
- **/init skip**: Model jumps straight to `/write src/main.rs` without scaffolding — `cargo build` then fails because there's no `Cargo.toml`.
- **Format string struggle**: 2B models especially struggle with Rust's `{:<6}` format specifiers, often producing invalid syntax.

---

## Workout Matrix

| Workout | Skills Tested | Commands Exercised | Research? | Expected Milestones |
|---------|--------------|-------------------|-----------|-------------------|
| 1. FizzBuzz | Decomposition, Rust syntax, escape handling | /init, /write, /build | No | 3-4 |
| 2. CSV Stats | Python stdlib, error handling, sequencing | /write, bash | No | 3-5 |
| 3. TIOBE Table | Web pipeline, data synthesis, Rust codegen | /web, /init, /write, /build | Yes | 4-7 |

---

## Edge Cases to Watch Across All Workouts

### Strategist

- **Tool leakage in honeydew items**: Items should say "Create the script" not "Use /write to create the script"
- **Over-decomposition**: Simple tasks get 5+ items; each item should map to ~1 milestone
- **Milestone deduplication**: Same milestone phrasing repeated after INCOMPLETE verdict
- **Write-for-everything (FIXED)**: Models default to "Use /write to..." for every milestone (build, scaffold, run) because /write was the only format example. Now: coding workflow card injected when task involves code, format examples include /init /build /test, and pre-route remaps /write to /init or /build when the milestone verb is unambiguously a coding action.

### Pre-Route

- **Lock-in**: Pre-route extracts a command from milestone text and the specialist parrots it even when context suggests a different tool
- **Respond→social confusion**: Milestone says "deliver via Discord" but pre-route extracts /respond (now caught by respond→social remap)
- **Write→init/build remap (FIXED)**: When pre-route extracts /write but the milestone says "build the project" or "scaffold a new Rust project," remap to /build or /init. Does NOT match "compile" (ambiguous — "compile a report" vs "compile code"). Uses language names (rust, python, cargo) and toolchain nouns as signal.

### Specialist

- **Escape corruption in /write**: Long `\\n`-delimited code files lose track of nesting (braces, parens, indentation)
- **Quote stripping interaction**: Specialist wraps args in quotes that get stripped, changing semantics
- **Bare command output**: Outputs just `/build` with no explanation vs. the expected format

### Evaluator

- **False COMPLETE on exit 0**: /write exits 0 but the content has placeholder text
- **Cross-milestone leakage**: P1 evaluator sees prior milestone data and marks COMPLETE prematurely
- **SATISFIED on generic output**: Honeydew evaluator marks research item SATISFIED from search result links without actual data

---

## Run Log

| Date | Model | Workout | Grade | Milestones | Notes |
|------|-------|---------|-------|------------|-------|
| 2026-03-09 | gemma-3-4b-it (google) | 1. FizzBuzz | **F** | 4 (cancelled M4) | All 4 milestones used /write. M1: wrote Hello World to responses/new_project.rs. M2: wrote `println!("FizzBuzz")` to src/main.rs (not actual FizzBuzz logic). M3: "compile" milestone used /write again (wrote Hello World to responses/main.rs). M4: "run executable" used /write — cancelled by user. No /init, no /build ever selected. Pre-routed /write from strategist milestone text. Evaluator marked all COMPLETE despite wrong commands. Root cause: strategist had no coding command descriptions, format examples only showed /write. |

---

## Future: RLHF Alignment Dataset Structure

> Not yet implemented. Placeholder for when we begin collecting preference pairs.

### Planned Schema

```json
{
  "workout_id": "fizzbuzz_rust_v1",
  "model": "qwen35-4b-think",
  "timestamp": "2026-03-09T15:00:00Z",
  "turns": [
    {
      "role": "strategist",
      "input_context": "<macro_memory + honeydew list>",
      "output": "Use /init to scaffold a Rust project named fizzbuzz",
      "chosen": true,
      "rejected_alternative": "/web search Rust FizzBuzz example",
      "reason": "No research needed for FizzBuzz — pure code generation"
    },
    {
      "role": "specialist",
      "input_context": "<micro_objective + action_log + syntax card>",
      "output": "/init fizzbuzz rust",
      "chosen": true,
      "rejected_alternative": "/init fizzbuzz Rust",
      "reason": "Type must be lowercase 'rust' per init.sh resolver"
    },
    {
      "role": "evaluator",
      "input_context": "<action_log with exit 0>",
      "output": "COMPLETE: project scaffolded with Cargo.toml and src/main.rs",
      "chosen": true,
      "rejected_alternative": "INCOMPLETE: FizzBuzz logic not yet written",
      "reason": "P1 evaluates milestone, not honeydew item — scaffold IS the milestone"
    }
  ],
  "preference_pairs": [
    {
      "context": "honeydew item 1: Create the Rust project and implement FizzBuzz logic",
      "chosen": "Use /write to implement FizzBuzz in src/main.rs",
      "rejected": "Use /web search to find Rust FizzBuzz examples",
      "margin": "strong"
    }
  ]
}
```

### Alignment Signals to Capture

| Signal | Source | What It Tells Us |
|--------|--------|-----------------|
| Command routing accuracy | Router / pre-route | Does the model pick the right tool? |
| Escape formatting quality | Specialist /write output | Can the model produce valid `\\n`-delimited code? |
| Decomposition granularity | Honeydew builder | Does the model create the right number of items? |
| Research→delivery transition | Strategist | Does the model know when to stop researching? |
| Evaluation calibration | P1 + honeydew evaluator | Does exit 0 ≠ task complete? |
| Recovery from failure | Escalation + rewrite | Does the model adapt when commands fail? |
