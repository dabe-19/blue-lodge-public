# Blue Lodge as a Personal Phone Assistant

Blue Lodge isn't just a coding agent — it's a local AI assistant that lives on your phone. Since it runs entirely offline via Ollama, it works on airplanes, in subways, and anywhere without cell service.

---

## Quick Questions (No Tools, Just Thinking)

Use `/ask` or just type a question with a `?`:

```
$ lodge
⌂ Blue Lodge v0.1.0

> What's the time complexity of a hash table lookup?
  Average O(1), worst case O(n) when all keys hash to the same bucket.

> /ask Explain the difference between TCP and UDP in 3 sentences
  TCP is connection-oriented — it establishes a session and guarantees 
  ordered delivery. UDP is connectionless — it sends packets without 
  confirmation, making it faster but unreliable. Use TCP for web/API 
  traffic, UDP for streaming/gaming where dropped packets are acceptable.

> What does the -z flag do in bash?
  Tests if a string is empty (zero length). `[[ -z "$var" ]]` returns
  true if $var is unset or "".
```

## Writing & Editing Help

```
> Write a professional email declining a meeting. Keep it short and polite.

  Subject: Re: Sync Meeting — Feb 23

  Hi [Name],

  Thanks for the invite. Unfortunately I have a conflict at that time 
  and won't be able to join. If there are action items for me, I'm happy 
  to follow up async.

  Best,
  [Your name]
```

## Clipboard Integration

Copy something on your phone, then ask Lodge about it:

```
> /phone clip
  (pastes clipboard contents)

> /ask What does this error mean? [paste the error]
```

Or have Lodge put something on your clipboard:

```
> /ask Give me a regex for validating email addresses
  ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$

> /phone clip ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$
  ✓ Copied to clipboard
```

## Quick Calculations & Conversions

```
> How many bytes in 1.5 gigabytes?
  1,610,612,736 bytes (1.5 × 1024³)

> Convert 72°F to Celsius
  22.2°C

> What's 15% tip on $47.80?
  $7.17 (total: $54.97)
```

## Learning & Study

```
> /ask Explain monads like I'm 5

> /ask What are the SOLID principles? Give me one sentence for each.

> /ask I'm learning Rust. What should I build after "Hello World"?
```

## Shell Scripting Help

Generate quick scripts without creating a full project:

```
> Write a bash one-liner that finds all files larger than 100MB in my home directory

  find ~ -type f -size +100M -exec ls -lh {} \;

> Write a cron expression for "every weekday at 9am"

  0 9 * * 1-5
```

## File Management

```
> /read ~/notes/shopping-list.txt
  milk
  eggs
  bread

> Append "butter" to my shopping list
  (Lodge writes the updated file)
```

## Phone Notifications as Reminders

```
> /phone notify "Take a break — you've been coding for 2 hours"
  ✓ Notification sent

> /phone toast "Build complete!"
  (Toast message appears on screen)
```

## Battery-Aware Usage

```
> /phone battery
  {"percentage": 34, "status": "discharging", "temperature": 31.2}

> /status
  Model:      blue-lodge
  Project:    ~
  Battery:    34%
```

When battery is low, Lodge's model unloading is especially valuable — it frees ~4GB of RAM after each interaction.

## Daily Workflow Examples

### Morning commute (offline)

```
$ lodge
> /ask Summarize the key points of the Strategy design pattern
> /ask Give me 3 Rust exercises for practicing lifetimes
> /ask What's the difference between Arc and Rc?
```

### Lunch break coding session

```
$ cd ~/my-project
$ lodge
> add input validation to the signup handler
> /fix
> /test
> /commit
```

### Evening learning

```
$ lodge
> /journal write "Learned about trait objects today. Dynamic dispatch 
  is like vtables in C++ but the syntax is cleaner. Still confused 
  about object safety rules."
```

### Quick script while waiting

```
$ lodge "Write a Python script that renames all .jpeg files in the 
  current directory to .jpg"
```

---

## Tips for Assistant Mode

1. **Short questions get fast answers** — Questions under ~6 words with a `?` go through the lightweight `/ask` path (single LLM call, no planning)

2. **Use `/ask` explicitly** — Forces quick-answer mode even for longer prompts. No files will be created or modified.

3. **Longer prompts trigger task mode** — If you write more than 6 words without a `?`, Lodge enters plan-then-execute mode. This is great for "build me X" but overkill for simple questions.

4. **Battery check before long tasks** — On low battery, consider using `LLM_KEEP_ALIVE=0` to unload the model immediately after each call.

5. **Journal your learning** — The journal persists across sessions. Use `/journal write "..."` to note what you learned. Lodge reads this context on the next session and it subtly shapes its responses.

6. **Clipboard is your bridge** — Copy from any app, paste into Lodge with `/phone clip`, ask about it, and copy the answer back.
