<div align="center">

<img src="docs/images/icon.png" width="128" alt="CodaPace icon">

# CodaPace

**Know whether you'll make it to the reset.**

A macOS menu bar app for API quota. It shows how much you've spent, and whether you're on track
to reach the next reset without running dry.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#install)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black)](#install)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](#development)
[![Release](https://img.shields.io/github/v/release/rigelmansid/CodaPace)](https://github.com/rigelmansid/CodaPace/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

**English** · [简体中文](README.zh-CN.md)

</div>

<table>
  <tr>
    <th>Menu bar popover</th>
    <th>Settings and saved accounts</th>
    <th>Usage history</th>
  </tr>
  <tr>
    <td><img src="docs/images/popover.png" width="240" alt="Popover showing today's quota with a pace verdict, trend and token charts"></td>
    <td><img src="docs/images/settings.png" width="300" alt="Settings window with the supported services and a list of saved accounts"></td>
    <td><img src="docs/images/history.png" width="300" alt="History window with a quota trend curve and daily token bars"></td>
  </tr>
</table>

---

## Why CodaPace

- **Pace, not just usage.** *61% remaining* means nothing until you know how much of the period is
  left. At 9 a.m. it's comfortable; at 11 p.m. it's irrelevant. CodaPace puts the two side by side:
  `pace = quota remaining % − time remaining %`. Negative means you'll run out before the reset.
- **A decision, not a statistic.** The verdict tells you whether to start the big refactor now or
  wait for the reset.
- **Two facts in the menu bar.** The number is how much is left; the caption is how fast it's going
  (*On pace* / *Over pace*). The outer ring is quota, the inner ring is time.
- **Nothing is invented.** Gaps stay gaps, estimates are labeled, and a quota with no reset cycle gets
  no verdict rather than a made-up one. See [Design stance](#design-stance-nothing-is-invented).

---

## Supported services

| Service | What you paste | Quotas | Where the credential lives |
|---|---|---|---|
| [claude-relay-service](https://github.com/Wei-Shaw/claude-relay-service) | The usage-stats page URL, `https://your-relay.example.com/admin-next/api-stats?apiId=…` | Total, daily, weekly Opus, rate-limit window | Preferences. The `apiId` is read-only and can't make requests |
| [tu-zi](https://api.tu-zi.com/) | An API key, `sk-…` | Daily, weekly, monthly | macOS Keychain, because the key can spend money |

It does **not** work with the official Anthropic API, Amazon Bedrock, Google Vertex AI, or gateways
such as LiteLLM and OpenRouter. Their usage APIs differ, and the official API has no per-key quota
endpoint at all.

Each service lives in a single adapter file. Everything else, including pace math, reset
inference, history, charts and alerts, is shared.

---

## Features

### Quota and pace
- The quota shown in the menu bar is featured at the top of the popover; the rest fold under
  **Other quota**
- Real currency amounts alongside percentages
- The menu bar can follow one quota, or pick the tightest one automatically
- Countdown recomputed locally every 30 seconds, independent of the network refresh

### Multiple accounts
- Save any account that passes **Test connection**, with a name of your choice
- Switch between saved accounts from the Settings window. History, learned reset times and alert
  state are kept per account, so nothing is lost when you switch back
- Deleting a saved account also removes its key from the Keychain; its history stays on disk

### History
- Local SQLite history: quota curves and daily token bars, in a resizable window
- 24-hour, 7-, 14- and 30-day ranges

### Menu bar and alerts
- Two styles: concentric rings or bars
- Alerts for *running low* and *being used quickly*, deduplicated per reset cycle so a 60-second
  refresh can't turn into a notification loop
- Status is never carried by color alone. Every state has an icon or a label
- When a new version is out, a row at the bottom of the popover links to its release page. It
  only tells you; downloading and installing stay in your hands

### Languages
- English, Simplified Chinese and Traditional Chinese, switchable without restarting

---

## Install

### Command line

Three commands: download the latest release, unzip it into Applications, and open it.

```bash
curl -fL -o /tmp/CodaPace.zip https://github.com/rigelmansid/CodaPace/releases/latest/download/CodaPace-arm64.zip
```

```bash
ditto -x -k /tmp/CodaPace.zip /Applications
```

```bash
open /Applications/CodaPace.app
```

A copy installed this way isn't quarantined, because `curl` doesn't mark what it downloads, so
macOS opens it without the Gatekeeper prompt.

To update, quit CodaPace and remove the old copy first, then run the three commands above:

```bash
osascript -e 'quit app "CodaPace"'
rm -rf /Applications/CodaPace.app
```

`ditto` merges into an existing app instead of replacing it, so skipping the removal can leave
files from the old version behind. Removing the app doesn't touch your accounts, saved list or
history, which live outside it.

### Download

Get `CodaPace-arm64.zip` from
[Releases](https://github.com/rigelmansid/CodaPace/releases/latest), unzip it, and move
`CodaPace.app` to Applications.

Releases are **ad-hoc signed and not notarized**, so a browser download is blocked on first launch:

1. **Control-click the app and choose Open.** On some macOS versions that's enough.
2. If it's still refused, open **System Settings → Privacy & Security** and click **Open Anyway**
   next to the message about CodaPace, then launch it again.

This happens once per copy. The command-line install above avoids it.

### Build from source

```bash
git clone https://github.com/rigelmansid/CodaPace.git
cd CodaPace
./build.sh
open build/CodaPace.app
```

Command Line Tools are enough; Xcode isn't needed. An app you build yourself isn't quarantined, so
it opens normally.

### Set up

The Settings window opens on first launch. Paste what your service's row asks for (see
[Supported services](#supported-services)) and press **Test connection**. It makes a real request
without saving anything, so a wrong URL or key is reported right away. Then **Save**. Keep
**Also save to the list** ticked to add the account to your saved accounts.

---

## Design stance: nothing is invented

Usage dashboards routinely interpolate across gaps, backfill zeros and smooth curves, and the reader
has no way to tell measured data from decoration. CodaPace refuses, consistently:

- **No pace verdict without a time window.** A quota with no reset cycle shows no verdict.
- **Gaps are shaded, never bridged with a solid line.** While the app isn't running there are no
  samples, and what happened in between is unknown.
- **Solid means observed, dashed means inferred.**
- **Reset boundaries break the curve.** A quota jumping back to full is an instant, known event, not
  a steep climb.
- **Estimated reset times are labeled** *(estimated)*, and corrected once a real reset is observed.
- **Token usage across midnight isn't split between days.** The total is known but the split isn't,
  so it's recorded as unattributed rather than guessed. Within a single day, it all counts toward
  that day.
- **Unknown units stay unknown.** If a service doesn't say what its numbers are in, they're shown
  as plain numbers, not dollars.

The cost is visible: charts have holes in them, especially early on. That's the honest picture.

---

## FAQ

<details>
<summary><b>macOS says the app can't be opened</b></summary>

Releases aren't notarized. Install from the [command line](#command-line) instead, which avoids
the prompt, or follow the two steps under [Download](#download).
</details>

<details>
<summary><b>Why does macOS ask for my password when I switch to a tu-zi account?</b></summary>

That's the Keychain asking whether CodaPace may read the saved key. Click **Always Allow**.
Because the app is ad-hoc signed, each new version counts as a new app to the Keychain, so you'll
see the prompt once per saved key after each update.
</details>

<details>
<summary><b>What data does CodaPace store, and where does it send it?</b></summary>

- **Network:** the relay URL you entered, or `coding.tu-zi.com` for tu-zi accounts, plus
  `api.github.com` once a day to check for a new version. The update check is an anonymous request
  for this project's latest release and carries nothing about you or your accounts. No analytics,
  no other hosts.
- **Preferences** (`~/Library/Preferences/com.hesher.codapace.plist`): the relay URL and `apiId`,
  the saved-account list (names and identifiers, no keys), and your display settings.
- **Keychain:** tu-zi API keys, under the service name `CodaPace`, readable only on this Mac.
- **History** (`~/Library/Application Support/CodaPace/History.sqlite`): partitioned by a hash of
  the service and account ID. The raw identifier is never written to the database.
</details>

<details>
<summary><b>Why is my chart full of gaps?</b></summary>

History is built from the app's own samples. The services only report current values, so nothing
before your install date exists, and nothing is recorded while the app isn't running. Those
periods are shaded instead of filled in.
</details>

<details>
<summary><b>Why does a reset time say "estimated"?</b></summary>

claude-relay-service doesn't publish its daily reset hour. CodaPace assumes local midnight until it
sees the counter drop to zero, then remembers the real hour for that account. tu-zi reports its
reset times, so they're never estimated.
</details>

<details>
<summary><b>Can I watch two accounts at once?</b></summary>

No. The menu bar has room for one number, and the popover, history and alerts all follow the
active account. Saved accounts make switching quick instead.
</details>

---

## Known limitations

- **History begins the day you install.** Nothing is backfilled.
- **No samples while the app isn't running.** Those periods appear as shaded gaps.
- **Charts have no hover tooltips.**
- **Over-pace alerts on short windows can repeat.** The rate-limit window resets hourly, so a
  sustained burst can produce one alert per hour.
- **Apple Silicon only, not notarized**, and Keychain prompts return after each update (see FAQ).

---

## Development

```bash
./build.sh                      # build CodaPace.app
swift run CoreTests             # 419 unit tests
swift Scripts/make-icon.swift   # regenerate Resources/AppIcon.icns
```

<details>
<summary><b>Project layout</b></summary>

```
Sources/Core/    pure logic — no AppKit, no SwiftUI, fully unit-tested
Sources/App/     SwiftUI views, menu bar rendering, networking, notifications, Keychain
Tests/CoreTests/ test harness and cases
Scripts/         icon generator
docs/            project notes and design backlogs (Chinese)
```

`Package.swift` exposes only `Sources/Core`, so the logic can be tested without the UI. `build.sh`
compiles `Core` and `App` together as one module.
</details>

<details>
<summary><b>About the test harness</b></summary>

Command Line Tools don't ship `XCTest.framework`; it comes only with Xcode, so `swift test` can't
run. `Tests/CoreTests/TestSupport.swift` provides assertion functions with XCTest's names and
signatures, plus an explicit registry in `TestRegistry.swift`. Test bodies are written as they
would be under XCTest.
</details>

<details>
<summary><b>The icon</b></summary>

`Scripts/make-icon.swift` draws the icon with CoreGraphics in sRGB and packages it with `iconutil`.
Every dimension is a fraction of the canvas, so all ten sizes from 16 to 1024 px are drawn from the
same logic rather than scaled down from one large image. The artwork is the menu bar indicator
enlarged: outer ring for quota, inner ring for time.
</details>

---

## Prior art and attribution

CodaPace owes a substantial debt to [CodexMeter](https://github.com/raycalrui/CodexMeter), a menu bar
monitor for Codex quota. Its published design notes shaped this app's interface and several of its
rules:

- **The pace idea itself**, weighing quota remaining against time remaining. The whole app is built
  around it.
- The dual concentric ring indicator, with the inner ring omitted when reset timing is unknown.
- A popover divided by rules rather than nested cards.
- Splitting pure logic into a separately testable module.
- Specific parameters: 15-minute anchor sampling, a 30-minute gap threshold, a 20% critical level,
  and alert deduplication per reset cycle.
- Signalling status with an icon or a label, not color alone.

**No CodexMeter source code was read or copied**, only its public README and architecture notes.
Everything here is written from scratch. The two apps read different backends and aren't
substitutes for each other.

Where CodaPace goes its own way: real currency amounts, learning the daily reset hour from observed
history, treating a gap (unknown middle, dashed bridge) differently from a reset (instant, known
jump), multiple services behind one adapter interface, and building without Xcode.

---

## License

[MIT](LICENSE)
