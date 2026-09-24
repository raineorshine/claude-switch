# claude-switch

Swap between Claude accounts (Code + Desktop) on macOS with a single command.

Claude Code credentials saved by csw live in macOS Keychain. Profile switching also moves and links Claude's existing configuration and Desktop data directories on disk. Optional local skill sharing stores the source profile name in the target profile directory.

## Install

### Option 1 — download binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mtxr/claude-switch/main/install.sh | bash
```

This downloads the latest release binary for your architecture (arm64 or x86_64) to `~/.local/bin/csw`.

### Option 2 — build from source

Requires [Zig 0.16.0](https://ziglang.org/download/) (or install via [mise](https://mise.jdx.dev): `mise use zig@0.16.0`).

```bash
git clone https://github.com/mtxr/claude-switch
cd claude-switch
zig build -Doptimize=ReleaseSmall
# binary at: zig-out/bin/csw
cp zig-out/bin/csw ~/.local/bin/csw
```

### Option 3 — manual download

Grab the binary for your architecture from [Releases](https://github.com/mtxr/claude-switch/releases), put it somewhere in your `$PATH`, and `chmod +x` it.

---

Make sure `~/.local/bin` is in your `$PATH` (add to `~/.zshrc` if needed):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

You also need [sk](https://github.com/lotabout/skim) or [fzf](https://github.com/junegunn/fzf) for the interactive picker:

```bash
brew install sk
```

## Migrating from the Python version

If you were using the previous Python-based `csw`, your profiles and keychain entries are **fully compatible** — no data migration needed. The Rust binary reads the exact same Keychain entries and file paths.

The only thing that changes is how `csw` is installed:

**1. Remove the old wrapper**

```bash
rm ~/.local/bin/csw ~/.local/bin/claude-switch
```

**2. Install the new binary**

```bash
curl -fsSL https://raw.githubusercontent.com/mtxr/claude-switch/main/install.sh | bash
```

**3. Verify everything still works**

```bash
csw whoami
csw list
```

Your profiles should appear exactly as before. Nothing to re-save.

> **Note:** `csw update` now self-updates by downloading the latest binary from GitHub Releases instead of running `git pull`. If you cloned the repo just for the Python version, you can delete it.

## Getting started

You need to save each account as a profile before you can switch between them. Do this once per account:

**1. Save your current account (e.g. work)**

```bash
csw save work
```

This saves the session tokens into macOS Keychain and migrates `~/.claude.json` and `~/.claude/` to profile-specific paths (`~/.claude.work.json`, `~/.claude.work/`), leaving symlinks in place. From now on, switching just swaps the symlinks.

**2. Create a slot for the second account and log in**

```bash
csw new personal   # creates ~/.claude.personal.json + ~/.claude.personal/, activates symlinks
claude auth login  # logs in as the personal account into the active slot
```

**3. Save the second account**

```bash
csw save personal
```

You're set. Switch between accounts instantly:

```bash
csw use work
csw use personal
# or interactively:
csw pick
```

### Skills and plugins in a new profile

`csw new` creates an empty `~/.claude.<profile>/` directory. Claude Code user
skills in `~/.claude/skills/` and installed plugins therefore do not appear in
the new profile automatically. The account's conversations and credentials stay
separate too.

To keep **local user skills** from `work` available in `personal`, opt in after
creating both profiles:

```bash
csw share-skills work personal
```

The command links local skills that are missing in `personal`. It preserves
same-named skills already there and never links Claude's account-specific
`skills/synced` directory. Edits to linked skills appear in both profiles;
new skills added to `work` are linked automatically the next time you run
`csw use personal`. Skills created only in `personal` stay there. Run
`csw unshare-skills personal` to stop refreshing and remove links pointing
to `work`. The source profile cannot be deleted while another profile shares
its skills.

**Plugins still need to be installed in each profile.** While `personal` is
active, for example, install Compound Engineering with:

```bash
claude plugin marketplace add EveryInc/compound-engineering-plugin
claude plugin install compound-engineering@compound-engineering-plugin
claude plugin list
```

Before declaring the profiles matched, compare the complete installed plugin
lists, including enabled status and versions. A plugin named in a missing
command report may be only one of several missing plugins. Repeat the comparison
after installation; the target should have no missing plugin IDs. Plugins shown
as available in an account's catalog are not necessarily installed.

Start a new Claude Code session to load the plugin. Plugin versions and updates
remain independent between profiles. Skills uploaded in Claude's **Customize →
Skills** are [tied to the signed-in Claude account](https://support.claude.com/en/articles/12512180-use-skills-in-claude);
these local links do not copy those uploads to another account.

## Usage

```
csw save <name>    Save current sessions (Code + Desktop) as a named profile
csw use <name>     Switch to a saved profile
csw new <name>     Create a new empty profile slot (then: claude auth login)
csw share-skills <source> <target>  Share local skills and refresh on switch
csw unshare-skills <target>         Stop sharing and remove shared links
csw delete <name>  Delete a profile and its data
csw list           List all saved profiles
csw whoami         Show active session info (Code + Desktop + saved profiles)
csw pick           Interactive fuzzy picker (sk / fzf)
csw update         Update csw to the latest release
csw logout-all     Log out of all accounts and remove active symlinks
```

## How it works

### Security model

csw saves Claude Code session credentials in **macOS Keychain** and moves Claude's local configuration and Desktop data into profile-specific paths. When skill sharing is enabled, the target profile also contains a `.csw-skills-source` file naming the source profile.

| Data | Where it lives |
|---|---|
| Claude Code tokens | Keychain: `csw-code-<profile>` |
| Active Code session | Keychain: `Claude Code-credentials` (managed by Claude) |
| Active Desktop session | Electron SQLite cookie, AES-128-CBC encrypted (managed by Claude Desktop) |
| Desktop encryption key | Keychain: `Claude Safe Storage` (managed by Claude Desktop) |
| Profile configs | `~/.claude.<profile>.json` + `~/.claude.<profile>/` |
| Active profile | `~/.claude.json` → symlink, `~/.claude/` → symlink |

- Account switching does not send tokens to a csw service.
- Both Claude Code and Claude Desktop are optional — csw works with either or both.
- On switch, Claude Desktop is quit automatically and relaunched.

### Profile switching

Switching profiles is instant because `~/.claude.json` and `~/.claude/` are symlinks. Changing them is an atomic filesystem operation — no copying, no rewriting.

Claude Desktop uses real directory renames instead of symlinks (Electron doesn't follow symlinks for its data directory). On switch, csw renames `Claude/` → `Claude.<from>/` and `Claude.<to>/` → `Claude/`.

## Development

```bash
git clone https://github.com/mtxr/claude-switch
cd claude-switch

# Debug build (fast compile, leak detection)
zig build

# Optimised builds
zig build -Doptimize=ReleaseSafe   # bounds checks on, ~670 KB
zig build -Doptimize=ReleaseSmall  # smallest binary
zig build -Doptimize=ReleaseFast   # max speed

# Run tests
zig build test
```

CI runs on every push: `zig build` (debug) and `zig build test`.

Releases are built automatically when a tag is pushed:

```bash
git tag v0.2.0
git push origin --tags
```

GitHub Actions cross-compiles arm64 and x86_64 binaries (`-Doptimize=ReleaseSmall`) and publishes them to the release.

## License

MIT — see [LICENSE](LICENSE).
