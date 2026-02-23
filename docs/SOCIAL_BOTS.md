# Social Bots & API Setup Guide

George can post, read, search, and interact on **five social platforms** — all via
pure `curl` + REST APIs. No SDKs, no Python, no Node.

| Platform   | Post | Read | Search | Reply | Delete | Notify |
|-----------|------|------|--------|-------|--------|--------|
| X/Twitter  | ✓    | ✓    | ✓      | ✓     | ✓      | —      |
| Mastodon   | ✓    | ✓    | ✓      | ✓     | —      | ✓      |
| Bluesky    | ✓    | ✓    | ✓      | —     | —      | —      |
| Discord    | ✓    | ✓    | —      | —     | —      | —      |
| Telegram   | ✓    | ✓    | —      | ✓     | —      | —      |

---

## Quick Start

```bash
# 1. Set an API key
/api keys set X_BEARER_TOKEN your-token-here

# 2. Post to that platform
/social x post Hello from George!

# 3. Post to ALL configured platforms at once
/social post Greetings from the Lodge.

# 4. Check what's configured
/social status
```

---

## X (Twitter) Setup

George uses the **X API v2** with a Bearer Token for authentication.

### Step 1: Create a Developer Account

1. Go to [developer.x.com](https://developer.x.com)
2. Sign in with your X/Twitter account
3. Click **Sign up for Free Account** (or choose a paid tier)
4. Complete the use-case description — say something like: "Automated posting
   from a local coding agent for personal project updates"
5. Accept the developer agreement

### Step 2: Create a Project & App

1. From the Developer Portal dashboard, click **+ Add Project**
2. Name it (e.g., `George Bot`)
3. Select your use case: **Making a bot**
4. Create an **App** within the project
5. Name the app (e.g., `george-lodge`)

### Step 3: Get Your Bearer Token

1. In your app settings, go to **Keys and tokens**
2. Under **Bearer Token**, click **Regenerate**
3. Copy the token immediately — it won't be shown again

### Step 4: Set App Permissions

If you want George to **post** (not just read), you must set write permissions:

1. App Settings → **User authentication settings** → **Set up**
2. App permissions: **Read and write**
3. Type of App: **Web App, Automated App or Bot**
4. Callback URL: `https://localhost` (placeholder — not used for Bearer auth)
5. Website URL: any valid URL
6. Save and confirm

> **Note**: The free tier allows 1,500 posts/month and 50 reads/day.
> For heavier usage, consider the Basic ($100/mo) or Pro tier.

### Step 5: Configure George

```bash
/api keys set X_BEARER_TOKEN AAAAAAAAAAAAAxxxxxxxxxx...
```

### Commands

| Command | Description |
|---------|-------------|
| `/social x post <text>` | Post a tweet |
| `/social x timeline` | View your recent tweets |
| `/social x search <query>` | Search recent tweets |
| `/social x reply <tweet_id> <text>` | Reply to a tweet |
| `/social x delete <tweet_id>` | Delete a tweet |

### OAuth 2.0 Note

George currently uses **Bearer Token** (app-level auth), which works for most
operations. For user-context operations (like reading home timeline, managing
lists, or DMs), you'd need **OAuth 2.0 User Context** — that requires a browser
redirect flow which is impractical in a mobile terminal. Bearer Token covers
posting, searching, and reading your own tweets.

---

## Mastodon Setup

Mastodon is federated — your account lives on an **instance** (server). George
works with any Mastodon-compatible instance (Mastodon, Hometown, Pleroma,
Akkoma, GoToSocial, etc.).

### Step 1: Pick Your Instance

If you don't already have an account:
- [mastodon.social](https://mastodon.social) — the flagship instance
- [infosec.exchange](https://infosec.exchange) — security-focused
- [fosstodon.org](https://fosstodon.org) — open-source focused
- [joinmastodon.org/servers](https://joinmastodon.org/servers) — full directory

### Step 2: Create an Application

1. Log in to your Mastodon instance in a browser
2. Go to **Preferences** → **Development** → **New Application**
3. Application name: `George` (or whatever you like)
4. Scopes (check these):
   - `read` — read your timeline and notifications
   - `write` — post statuses and replies
   - `follow` — optional, for managing follows
5. Redirect URI: leave as `urn:ietf:wg:oauth:2.0:oob`
6. Click **Submit**

### Step 3: Get Your Access Token

1. Click on your new application name
2. Copy the **Your access token** value
3. Also note your instance URL (e.g., `https://mastodon.social`)

### Step 4: Configure George

```bash
/api keys set MASTODON_INSTANCE https://mastodon.social
/api keys set MASTODON_ACCESS_TOKEN your-access-token-here
```

> If you skip `MASTODON_INSTANCE`, George defaults to `mastodon.social`.

### Commands

| Command | Description |
|---------|-------------|
| `/social mastodon post <text>` | Post a status (toot) |
| `/social mastodon timeline` | View your home timeline |
| `/social mastodon search <query>` | Search statuses |
| `/social mastodon notify` | View recent notifications |

### Visibility Options

George defaults to `public` visibility. To change this programmatically, you
can call the function directly: `mastodon_post "text" "unlisted"`. Valid values:
- `public` — visible on public timelines
- `unlisted` — visible on your profile, not on public timelines
- `private` — followers only
- `direct` — mentioned users only (like a DM)

---

## Bluesky Setup

Bluesky uses the AT Protocol. Authentication uses **App Passwords** — you
never give George your main password.

### Step 1: Create an Account

1. Go to [bsky.app](https://bsky.app) and sign up (or use an existing account)
2. Your handle will be something like `yourname.bsky.social`

### Step 2: Create an App Password

1. Go to **Settings** → **Privacy and security** → **App passwords**
2. Click **Add App Password**
3. Name it `george` (this is just a label)
4. Copy the generated password (looks like `xxxx-xxxx-xxxx-xxxx`)

> App passwords are **scoped** — they can't change your account password
> or email, making them safe for bot use.

### Step 3: Configure George

```bash
/api keys set BLUESKY_HANDLE yourname.bsky.social
/api keys set BLUESKY_APP_PASSWORD xxxx-xxxx-xxxx-xxxx
```

### Commands

| Command | Description |
|---------|-------------|
| `/social bluesky post <text>` | Post a skeet |
| `/social bluesky timeline` | View your home timeline |
| `/social bluesky search <query>` | Search posts |

### Session Management

George automatically handles Bluesky's JWT session. On the first request of
each session, George calls `com.atproto.server.createSession` to authenticate.
The JWT token is cached in memory for subsequent requests. If you get auth
errors, just try again — George will re-authenticate.

---

## Discord Bot Setup

George supports Discord through **two mechanisms**:
1. **Webhooks** — simplest, just post messages to a channel (no bot account)
2. **Bot Account** — full API access, read messages, manage channels

### Option A: Webhook (Easiest)

Perfect for one-way notifications (George → Discord).

#### Step 1: Create a Webhook

1. Open Discord → go to your server
2. Click the **gear icon** next to the channel you want George to post in
3. Go to **Integrations** → **Webhooks** → **New Webhook**
4. Name it `George` (this appears as the bot's display name)
5. Upload an avatar if you want
6. Click **Copy Webhook URL**

#### Step 2: Configure George

```bash
/api keys set DISCORD_WEBHOOK_URL https://discord.com/api/webhooks/123456/abcdef...
```

#### Usage

```bash
/social discord send Hello from George!
```

That's it. No bot account needed, no permissions to configure.

### Option B: Full Bot Account

For reading messages, responding to events, and posting to multiple channels.

#### Step 1: Create an Application

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Click **New Application**
3. Name it `George`
4. Note the **Application ID** (you'll need it for the invite link)

#### Step 2: Create the Bot

1. In your application, go to the **Bot** section
2. Click **Add Bot** → confirm
3. Under **Token**, click **Reset Token**
4. Copy the token immediately

#### Step 3: Set Permissions

Under **Bot** → **Privileged Gateway Intents**, enable:
- **Message Content Intent** — required to read message text
- **Server Members Intent** — optional, needed for member lists

#### Step 4: Invite to Your Server

Build an invite URL:
```
https://discord.com/api/oauth2/authorize?client_id=YOUR_APP_ID&permissions=3072&scope=bot
```

- `permissions=3072` = Send Messages (2048) + Read Message History (1024)
- For more permissions, use the [Permission Calculator](https://discordapi.com/permissions.html)

Open this URL in a browser, select your server, and authorize.

#### Step 5: Get a Channel ID

1. In Discord, go to **User Settings** → **Advanced** → enable **Developer Mode**
2. Right-click any channel → **Copy Channel ID**

#### Step 6: Configure George

```bash
/api keys set DISCORD_BOT_TOKEN your-bot-token-here
```

#### Commands

| Command | Description |
|---------|-------------|
| `/social discord send <text>` | Send via webhook |
| `/social discord read <channel_id>` | Read recent messages from a channel |

> For `discord_send` (bot-mode channel posting), call the function directly
> with a channel ID: `discord_send "CHANNEL_ID" "message"`

---

## Telegram Bot Setup

Telegram bots are created through the **BotFather** — a special Telegram bot
that manages other bots.

### Step 1: Create a Bot via BotFather

1. Open Telegram and search for **@BotFather** (verified ✓)
2. Start a conversation and send: `/newbot`
3. BotFather asks for a **display name** — enter: `George`
4. BotFather asks for a **username** — enter something unique ending in `bot`:
   `george_lodge_bot` (must be globally unique)
5. BotFather responds with your **bot token** — looks like:
   `123456789:ABCdefGHIjklMNOpqrSTUv-wxyz12345`

### Step 2: Get Your Chat ID

George needs to know where to send messages. To get your personal chat ID:

1. Send any message to your new bot in Telegram
2. Open this URL in a browser (replace `TOKEN` with your bot token):
   ```
   https://api.telegram.org/botTOKEN/getUpdates
   ```
3. Find `"chat": {"id": 123456789}` in the response
4. That number is your chat ID

**Alternative** — use the `/social telegram me` command after setting the token:
```bash
/api keys set TELEGRAM_BOT_TOKEN 123456789:ABCdefGHIjklMNOpqrSTUv-wxyz12345
/social telegram me    # Confirms George can reach the API
```

Then send a message to the bot and check updates:
```bash
# After sending a message to the bot in Telegram:
/social telegram updates
```

The output will show your chat ID.

### Step 3: Configure George

```bash
/api keys set TELEGRAM_BOT_TOKEN 123456789:ABCdefGHIjklMNOpqrSTUv-wxyz12345
/api keys set TELEGRAM_CHAT_ID 123456789
```

### Commands

| Command | Description |
|---------|-------------|
| `/social telegram send <text>` | Send a message to the default chat |
| `/social telegram updates` | View recent messages to the bot |
| `/social telegram me` | Show bot info (verify connection) |

### Bot Privacy Settings

By default, Telegram bots can only see messages that:
- Are sent directly to the bot
- Start with a `/` command in groups
- Mention the bot by @username

To let George see all group messages:
1. Message @BotFather: `/setprivacy`
2. Select your bot
3. Choose **Disable** (turns off privacy mode)

### Rich Messages

George sends messages with `parse_mode: Markdown`, so you can use:
- `*bold*` → **bold**
- `_italic_` → *italic*
- `` `code` `` → `code`
- `` ```code block``` `` → code block

---

## Unified Posting

The most powerful feature — post to multiple platforms simultaneously:

```bash
# Post to ALL configured platforms
/social post Just shipped a new feature!

# Post to a specific platform
/social post x New release v0.2 is live!
/social post mastodon Latest update from the lodge
/social post telegram Build passed ✓
```

George checks which platforms have API keys configured and only attempts
those. The results show success/failure for each:

```
── Post Results ──────────────────────────────
  X: ✓
  Mastodon: ✓
  Discord: ✓
  Telegram: ✗
```

---

## Checking Status

```bash
/social status
```

Shows which platforms are configured:
```
── Social Integrations ──────────────────────
  ● X               configured
  ● MASTODON        configured
  ○ BLUESKY         not configured
  ● DISCORD         configured
  ○ TELEGRAM        not configured
```

```bash
/api keys list
```

Shows all stored API keys (values masked):
```
── Configured API Keys ──────────────────────
  X_BEARER_TOKEN                 ********...
  MASTODON_ACCESS_TOKEN          ********...
  DISCORD_WEBHOOK_URL            ********...
```

---

## Managing Keys

```bash
# Set a key
/api keys set KEY_NAME value

# Remove a key
/api keys rm KEY_NAME

# List all keys
/api keys list

# Or edit the file directly
nano ~/.george/keys.conf
```

The keys file lives at `~/.george/keys.conf` with `600` permissions (owner
read/write only). **Never commit this file to git.**

---

## Security Considerations

- **All keys stored locally** in `~/.george/keys.conf` with restrictive
  permissions (mode 600). Nothing is sent to any cloud service except the
  explicit API calls you make.

- **Bearer tokens vs OAuth**: George uses Bearer tokens (app-level auth) where
  possible. This is simpler but means the token has full app permissions.
  Revoke tokens immediately if compromised.

- **App Passwords** (Bluesky): These are scoped — they can't change your
  Bluesky account password or email.

- **Webhook URLs** (Discord): Anyone with the URL can post to your channel.
  Treat it like a password.

- **Bot Tokens** (Discord, Telegram): Full bot access. Store securely and
  never share.

- **Rate Limits**: George handles `429` responses with exponential backoff via
  `api_retry`. X free tier is particularly restrictive (1,500 posts/month).

- **Secrets Vault**: For extra protection, store critical tokens in George's
  encrypted vault (`/secret set X_BEARER_TOKEN <value>`) — though for
  day-to-day use, `keys.conf` is sufficient.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "X_BEARER_TOKEN not configured" | `/api keys set X_BEARER_TOKEN <token>` |
| "Mastodon post failed" | Check instance URL: `/api keys set MASTODON_INSTANCE https://your.instance` |
| "Bluesky login failed" | Verify handle format includes `.bsky.social`; regenerate app password |
| "Discord webhook failed" | Webhook URLs expire if the webhook is deleted — recreate in Discord |
| "Telegram send failed" | Verify bot token with `/social telegram me`; check chat ID |
| "Rate limited (429)" | Wait and retry. X free tier is very restrictive |
| "HTTP request failed (curl exit: 6)" | DNS resolution failed — check network connectivity |
| "HTTP request failed (curl exit: 28)" | Timeout — increase `API_DEFAULT_TIMEOUT` or check connection |

---

## Architecture Notes

George's social system is built in three layers:

1. **lib/api.sh** — REST client core: HTTP methods, auth headers, JSON helpers,
   rate-limit retry, key management
2. **lib/social.sh** — Platform-specific functions: each platform's endpoints,
   data formatting, response parsing
3. **lodge** — Command dispatcher: maps `/social` commands to functions,
   handles argument parsing

All HTTP requests go through `api_request()`, which:
- Adds a User-Agent header (`George/0.1`)
- Enforces a 30-second timeout
- Returns the HTTP status code separately from the body
- Handles 429 (rate limit) with a specific return code
- Logs errors for 4xx and 5xx responses

The `social_post` unified dispatcher checks which keys exist before attempting
each platform, so misconfigured platforms are silently skipped when using "all".

---

## Platform API References

For deeper customization or debugging:

- **X API v2**: [developer.x.com/en/docs](https://developer.x.com/en/docs)
- **Mastodon API**: [docs.joinmastodon.org/api](https://docs.joinmastodon.org/api/)
- **AT Protocol** (Bluesky): [docs.bsky.app](https://docs.bsky.app/)
- **Discord API**: [discord.com/developers/docs](https://discord.com/developers/docs/)
- **Telegram Bot API**: [core.telegram.org/bots/api](https://core.telegram.org/bots/api)
