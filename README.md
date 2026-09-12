# CodaPace

**English** · [简体中文](README.zh-CN.md)

**Know whether you'll make it to the reset.**

A macOS menu bar app for watching Claude API quota — not just how much you've spent,
but whether you're on track to reach the next reset without running dry.

> **Prerequisite:** CodaPace reads usage from a relay running
> [claude-relay-service](https://github.com/Wei-Shaw/claude-relay-service). It does **not** work with
> the official Anthropic API, Bedrock, Vertex, or other gateways — see
> [Requirements](#requirements).

<p align="center">
  <img src="docs/images/menubar-popover.png" width="320"
       alt="CodaPace popover showing four quotas with pace verdicts and history charts">
</p>

---

## Why another usage monitor

Most usage monitors answer *how much have I used*. On its own, that number can't be acted on:
**61% remaining** means nothing until you know how much of the period is left. At 9 a.m. it's
comfortable. At 11 p.m. it's irrelevant.

CodaPace puts the two side by side:

```
pace = quota remaining % − time remaining %
```

A negative value means you're consuming faster than the clock — you'll run out early. That is a
decision, not a statistic: it tells you whether to start the big refactor now or wait for the reset.

The menu bar carries both dimensions at once:

| | |
|---|---|
| **Number** | quantity — how much is left |
| **Caption** | rate — *On pace* / *Over pace* |
| **Outer ring** | quota remaining, colored by status |
| **Inner ring** | time remaining |

Two orthogonal facts. The caption never restates the number — and when a quota has no reset cycle
(the account-wide total), where rate is undefined, it falls back to the remaining dollar amount
rather than showing a verdict it cannot compute.

---

## Design stance: nothing is invented

This is the part worth reading the source for. Usage dashboards routinely interpolate across gaps,
backfill zeros, and smooth curves — and the reader has no way to tell measured data from decoration.
CodaPace refuses, consistently:

- **No pace verdict without a time window.** The account-wide total quota has no reset cycle, so it
  simply shows no verdict rather than inventing one.
- **Gaps are shaded, never bridged with a solid line.** While the app isn't running there are no
  samples, and what happened in between is genuinely unknown.
- **Solid means observed, dashed means inferred.** Two visually distinct strokes, one meaning each.
- **Reset boundaries break the curve.** A quota jumping back to full is an instantaneous known event,
  not a steep climb — drawing a slope there would imply a gradual transition that never happened.
- **Inferred reset times are labeled** *(estimated)* — and corrected automatically once the app
  observes a real reset in the recorded history.
- **Token deltas spanning gaps longer than 30 minutes are discarded.** That usage crossed too much
  time to attribute to any single day, so it is left out rather than guessed at.
- **Unlimited quotas draw no percentage.** Without a ceiling there is no "remaining %".

The cost is visible: charts have holes in them, especially early on. That's the honest picture.

---

## Features

- Four quotas at a glance — total, daily, weekly Opus, and the rate-limit window — each with real
  currency amounts, not just percentages
- Two menu bar styles: concentric rings or stacked bars
- Local usage history in SQLite: quota curves and daily token bars, with a resizable history window
- Quota alerts for *running low* and *being used quickly*, deduplicated per reset cycle so a
  60-second refresh loop can't turn into a notification loop
- Status is never carried by color alone — every state has an icon or a label
- Simplified Chinese, Traditional Chinese, and English, switchable without restarting
- Countdown recomputed locally every 30 seconds, independent of the network refresh

---

## Prior art and attribution

CodaPace owes a substantial debt to [CodexMeter](https://github.com/raycalrui/CodexMeter), a menu bar
monitor for Codex quota. Its published design notes shaped both this app's interface and several of
its rules:

- **The pace idea itself** — weighing quota remaining against time remaining instead of reporting
  consumption alone. The entire app is built around this concept.
- The dual concentric ring indicator, and the rule that the inner ring is omitted when reset timing
  is unknown.
- A popover divided by rules rather than nested cards.
- Splitting pure logic into a separately testable module.
- Specific parameters: 15-minute anchor sampling, a 30-minute gap threshold, a 20% critical level,
  and deduplicating notifications per reset cycle.
- Signalling status with an icon or a label rather than color alone.

**No CodexMeter source code was read or copied** — only its public README and architecture notes.
Everything here is written from scratch.

The two apps are not substitutes for each other. CodexMeter reads Codex quota by spawning a local
`codex app-server` and speaking JSON-RPC over stdio; CodaPace reads an HTTP endpoint on a
claude-relay-service instance. Neither can talk to the other's backend.

Where CodaPace goes its own way:

- **Real currency amounts**, not just percentages — the relay API reports spend, and Codex's doesn't
- **Learns the daily reset hour from observed history**, because that API doesn't publish one, and
  labels the value *(estimated)* until it does
- **Distinguishes two kinds of discontinuity**: a gap is bridged with a dashed line because the
  middle is unknown; a reset is not, because the jump is instantaneous and known — instead a new
  cycle starts from a dashed 100% at the boundary
- **Builds and tests without Xcode**, using `swiftc` directly and a small XCTest-compatible harness

---

## Requirements

- **macOS 13 or later, Apple Silicon only.** The build is `arm64`; Intel Macs cannot run it.
- **A relay running [claude-relay-service](https://github.com/Wei-Shaw/claude-relay-service).**

That second requirement is the important one. CodaPace reads two endpoints
(`/apiStats/api/user-stats` and `/apiStats/api/batch-stats`) with the response shape that project
defines. It does **not** work with:

- the official Anthropic API — it exposes no equivalent per-key quota endpoint
- Amazon Bedrock or Google Vertex AI
- other gateways such as LiteLLM or OpenRouter, whose usage APIs differ

Only the response models and the two network calls are provider-specific. Everything else — pace
math, reset-cycle inference, history storage, chart series, alert policy — is provider-agnostic and
lives in a separately testable module.

---

## Install

### Build from source

```bash
git clone https://github.com/rigelmansid/CodaPace.git
cd CodaPace
./build.sh
open build/CodaPace.app
```

No Xcode required — Command Line Tools are enough.

Building it yourself produces an app you can open normally — macOS only quarantines apps that arrive
from a browser or another machine.

### If you got a prebuilt copy instead

Builds are **ad-hoc signed and not notarized** — `Signature=adhoc`, no Team ID. A copy that arrived
by download, AirDrop, or from another machine carries a quarantine flag, and Gatekeeper will refuse
to open it.

To open it anyway:

1. **Control-click the app and choose Open.** On some macOS versions this is enough.
2. If macOS still refuses, open **System Settings → Privacy & Security**, scroll to the security
   section, and click **Open Anyway** beside the message about the blocked app. Then launch it again.

Either way it's a one-time step per copy. Removing the friction properly requires a Developer ID
certificate and notarization, which this project doesn't have — so if that warning is a dealbreaker,
build from source instead.

### Setup

CodaPace opens its setup window on first launch. Open your relay's usage-stats page in a browser and
paste the full address:

```
https://your-relay.example.com/admin-next/api-stats?apiId=…
```

Use **Test connection** before saving — it performs a real request without storing anything, so a
wrong URL or apiId is reported immediately instead of surfacing later as a silent "Offline".

---

## Data and privacy

- **CodaPace talks to exactly one host: the relay URL you provide.** No analytics, no other network
  calls.
- **The `apiId` is stored in plain text** in `~/Library/Preferences/com.hesher.codapace.plist`,
  alongside the base URL. It is a read-only statistics identifier: it cannot issue API requests and
  cannot reveal your API key. It was previously kept in the Keychain, but Keychain access is bound to
  the code-signing identity, and an ad-hoc signature changes on every build — which made macOS demand
  the user's login password at every launch. For an unsigned app that prompt is indistinguishable
  from malware, and the thing it protected did not justify it.
- **History is local**, in `~/Library/Application Support/CodaPace/History.sqlite`, partitioned by a
  SHA-256 of the `apiId` so switching keys keeps histories separate. The raw `apiId` is never written
  to the database.

---

## Known limitations

- **History begins the day you install.** The relay API only reports current values; there is no
  historical endpoint. Nothing is backfilled.
- **No samples while the app isn't running.** Those periods appear as shaded gaps.
- **The daily reset hour is inferred.** The API doesn't publish it, so CodaPace assumes local
  midnight, marks that quota *(estimated)*, and learns the real hour the first time it observes the
  counter drop to zero.
- **Charts have no hover tooltips yet.** `chartXSelection` requires macOS 14; a manual
  implementation is pending.
- **Over-pace alerts on the rate-limit window can be chatty.** That window resets hourly, so its
  dedupe key changes every hour — a sustained burst could produce one notification per hour. The
  low-quota alert on that window is worth keeping (you're about to be throttled); the over-pace one
  probably isn't. Not yet fixed.
- **Apple Silicon only**, and **not notarized**.

---

## Development

```bash
./build.sh                      # build CodaPace.app
swift run CoreTests             # 119 unit tests
swift Scripts/make-icon.swift   # regenerate Resources/AppIcon.icns
```

### Layout

```
Sources/Core/    pure logic — no AppKit, no SwiftUI, fully unit-tested
Sources/App/     SwiftUI views, menu bar rendering, networking, notifications
Tests/CoreTests/ test harness and cases
Scripts/         icon generator
```

`Package.swift` exposes only `Sources/Core`, so the logic can be tested without touching the UI.
`build.sh` compiles `Core` and `App` together as a single module, so both sides share one copy of
the source.

### About the test harness

Command Line Tools do not ship `XCTest.framework` — it comes only with Xcode — so `swift test`
cannot run here. `Tests/CoreTests/TestSupport.swift` provides assertion functions with the same
names and signatures as XCTest, plus an explicit registry in `TestRegistry.swift`. Test bodies are
written exactly as they would be under XCTest; the file header documents how to switch back in four
steps once Xcode is available.

### The icon

`Scripts/make-icon.swift` renders the icon with CoreGraphics and packages it via `iconutil`. Every
dimension is expressed as a fraction of the canvas, so all ten sizes from 16pt to 1024pt are rendered
from the same logic rather than downscaled from a single large image — which matters, because the
sizes that decide whether an icon is usable are 32pt and 16pt, not 1024.

The artwork is the menu bar indicator, enlarged: outer ring for quota, inner ring for time, inner
stroke at 80% of the outer — the same ratio the app itself uses. What you see in the Dock and what
you see in the menu bar are the same object.

---

## License

MIT
