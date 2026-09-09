# Audio support — implementation plan

**Status:** Phases 1–4 complete and **verified on real hardware** — a Mac
streaming to an iPhone 16 Pro Max over WiFi, with audible audio. Capture,
encode, send, receive, decode and play all confirmed working; measured 0 decode
failures, 0 underruns, 0 drops.

Bringing it up on-device took five distinct fixes, each masking the next — see
§12. The most useful lesson: `AVAudioConverter` reports `inputRanDry` rather
than an error when its output buffer is the wrong size, so a total failure
logged nothing at all.

Goal: the virtual display also carries system audio, over **USB or WiFi**,
playing out on the receiver (iPhone/iPad, and the standalone Mac receiver).

Two decisions are already locked from the design discussion:

* **Transport:** tagged frames, a `pv 4` wire change (§2).
* **Capture:** ScreenCaptureKit audio first; the CoreAudio HAL driver is a
  later, optional phase (§3, §8).

---

## 1. Why this shape

Three constraints drove it, all verified against the current code rather than
assumed:

**The demultiplexer is a heuristic.** `Shared/StreamReceiver.swift:1003`
separates control JSON from video by sniffing for a leading `{` and the
absence of `0x00`:

```swift
if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0x00) {
    handleVideoChannelJSON(data)
```

Video frames also begin with `{` (a telemetry prefix); the NUL bytes in Annex B
start codes are what disambiguate them. Compressed audio has neither property
reliably — an AAC packet whose first byte is `0x7B` and which happens to contain
no NUL byte would be routed into `handleVideoChannelJSON`. Rare, silent, and
miserable to debug. A third payload kind needs a real tag, not a third sniff.

**UDP does not survive USB.** The cursor side channel is UDP and explicitly
WiFi-only — `Mac/MacSender.swift:1539` guards `case .tcp = transport` with the
comment *"usbmuxd tunnels TCP streams, there is no UDP through it."* The
requirement says USB **or** WiFi, so a cursor-style side channel would deliver
audio on WiFi and silence on USB.

**Audio is not droppable.** The cursor channel tolerates loss because the next
120Hz poll corrects it. A lost audio packet is an audible click and can desync
the decoder. Audio wants the reliable stream.

Tagged frames keep one code path across both transports — the property
`PROTOCOL.md:47` calls the most load-bearing decision in the protocol — and
retire the sniffing heuristic instead of extending it.

---

## 2. Wire format (`pv 4`)

### 2.1 Frame layout

Today every frame is `[4-byte big-endian length][payload]`, with the payload
kind inferred. Under `pv 4` a tagged frame is:

```
[4-byte big-endian length][1-byte type][payload]
```

where `length` counts the type byte plus payload, so the deframing loop's
bounds arithmetic is unchanged.

| type | meaning                        |
|-----:|--------------------------------|
| `0`  | video, Annex B (today's video) |
| `1`  | control JSON (today's JSON)    |
| `2`  | audio packet (new)             |

Unknown type bytes are logged once and skipped — the same log-and-ignore
posture `COMPATIBILITY.md:146` already requires for unknown message types, and
what makes a future type `3` additive.

### 2.2 Negotiation, and the one hazard worth care

Tagging is **negotiated, not assumed**. `WireProtocol.version` goes to `4`;
`pencilWireVersion` and `minSupportedPeer` are untouched. Both ends emit tagged
frames only when the peer advertises `pv >= 4`, and `pv` is known from `hello`
(receiver → sender, `StreamReceiver.swift:838`) and `welcome` (sender →
receiver, `MacSender.swift:2209`).

The hazard: **the handshake itself cannot be tagged**, because at that moment
neither end knows the peer's `pv`. So `hello` and `welcome` are always sent
untagged, and the tagged path activates only after the handshake resolves. On
the receiver this means the first frames off a fresh connection must go through
the legacy sniffing path regardless of what `pv` later turns out to be. Getting
this wrong produces a connection that works on WiFi, fails on reconnect, or
works only when the handshake happens to arrive in one TCP segment — so it gets
an explicit test (§6).

The mode is therefore per-connection state, latched when the peer's `pv` is
known and reset on every reconnect, not a global.

### 2.3 Audio packet payload

Type `2` payload is a small binary header plus one compressed audio packet:

```
[1]  codec        0 = AAC-LC
[1]  flags        bit0 = codec config present
[4]  sampleRate   Hz, big-endian (48000, 44100, …)
[8]  ptsMs        IEEE 754 double, big-endian — sender-clock capture time
[1]  channels     1 = mono, 2 = stereo
[..] payload      compressed audio
```

**Corrected during implementation.** This header originally specified the
sample rate as "kHz × 10" in two bytes. That unit cannot represent 22050 Hz —
it needs 220.5 — so the rate silently rounded to 22100 and a receiver decoding
at the rounded rate would drift against the sender for the whole session.
44100 survived only by coincidence (441 exactly), which is what made the flaw
easy to miss. The field is now plain Hz in four bytes, and
`testCommonSampleRatesRoundTrip` covers the range CoreAudio actually produces.

`ptsMs` is on the **sender's clock**, identical in meaning to the `captureMs`
already carried for video. That is what makes A/V sync free: the receiver
already computes a sender↔receiver clock offset via ping/pong
(`StreamReceiver.swift:726`, `clockOffsetMs`) and already maps video capture
timestamps through it (`:1186`). Audio reuses the same offset. No new timebase.

**Codec config is not transmitted.** The plan was for the AAC
`AudioSpecificConfig` to ride the first packet with the `flags` bit set, mirroring
video's SPS/PPS. In practice it never was — the sender captured the cookie and
never sent it, and neither side read the flag, which is why the decoder rejected
every frame until this was found on hardware.

Rather than wire the transmission, the receiver now **reconstructs** it: for
AAC-LC the config is two bytes fully determined by the sample rate and channel
count, and every packet already carries both. The `flags` bit stays reserved in
the header for a codec that does need out-of-band setup.

---

## 3. Capture (Mac sender)

`SCStreamConfiguration` gains audio on the **existing** stream
(`Mac/MacSender.swift:680`):

```swift
config.capturesAudio = true
config.sampleRate = 48_000
config.channelCount = 2
config.excludesCurrentProcessAudio = true   // never capture our own output
```

and a second stream output alongside the existing `.screen` one
(`MacSender.swift:702`):

```swift
try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
```

Three properties make this the right phase-1 capture:

* The sender is already pinned to macOS 14 (`project.yml`), so
  `capturesAudio` is unconditionally available — no new floor.
* Audio and video come from **one** `SCStream`, so they share a capture clock.
  Sync is inherent, not reconstructed.
* Zero install friction: no installer, no admin rights, no HAL bundle. The
  current drag-to-install DMG and Sparkle updates keep working untouched.

`excludesCurrentProcessAudio` matters more than it looks: without it, the
receiver's own audio (if the Mac receiver plays it out) can loop back into
capture.

**Encode:** `AudioConverterRef` (or `AVAudioConverter`) PCM → AAC-LC at
~128 kbps stereo, on a dedicated serial queue. Never on the video queue —
sharing it would let an audio hiccup stall frame delivery.

**Backpressure:** audio is small (~16 KB/s) next to video, but it must not
queue unboundedly behind a stalled video send. If `pendingSends`
(`MacSender.swift:2245`) is above a threshold, drop the oldest audio packet
rather than growing the queue: late audio is worse than absent audio.

---

## 4. Playback (receivers)

### 4.1 iOS

Decode AAC via `AudioConverter`, play through `AVAudioEngine` +
`AVAudioPlayerNode`, or `AudioQueue` if the jitter buffer proves easier there.

Session category `.playback` with `.mixWithOthers` so OpenDisplay's audio does
not silence the user's music by default — this should be a user-visible
preference, not a silent policy choice.

Backgrounding: `StreamReceiver` already has a `renderingPaused` concept for
video (`:1105`). Audio needs the parallel decision — an audio session that
keeps playing while backgrounded needs the `audio` background mode in
`Info.plist`, which has App Store review implications. **Open question for
review (§9).**

### 4.2 Standalone Mac receiver

`AVAudioEngine` equally, and it must build at the receiver's **macOS 12**
deployment floor (`project.yml`) — lower than the sender's 14. Anything added
to `Shared/` must compile at 12. CI already guards this by building the
receiver target specifically to catch newer APIs leaking into `Shared/`
(`.github/workflows/tests.yml`, issue #241), so a violation fails CI rather
than shipping.

### 4.3 Jitter buffer

A small adaptive buffer (target ~60–80 ms, bounded) absorbs network jitter.
Underrun inserts silence; sustained overrun drops the oldest packet. Report
depth, underruns, and drops into the existing `stats` control message
(`StreamReceiver.swift:1240`) so audio health shows up in the perf overlay
next to the video numbers, and in the Mac's log for offline analysis.

---

## 5. Files touched

| File | Change |
|---|---|
| `Shared/Protocol.swift` | `version = 4`; `taggedFrameVersion = 4`; `FrameType` enum; `WireMessage` audio types |
| `Shared/AudioPacket.swift` *(new)* | header encode/decode, Foundation-only |
| `Mac/MacSender.swift` | `capturesAudio`, `.audio` stream output, AAC encoder, tagged `sendFramed`/`sendJSONFrame` |
| `Mac/AudioEncoder.swift` *(new)* | PCM → AAC, isolated from the sender |
| `Shared/StreamReceiver.swift` | tagged `drainFrames`, audio route, jitter buffer, stats |
| `Shared/AudioPlayer.swift` *(new)* | `AVAudioEngine` playback, must compile at macOS 12 |
| `iOS/OpenSidecarPhoneApp.swift` | audio session, mute/volume UI |
| `MacReceiver/ReceiverPanel.swift` | mute/volume UI |
| `project.yml` | new `Shared/` files land in all three targets automatically |
| `PROTOCOL.md` | §on framing → `pv 4` tagged frames; audio packet spec |
| `COMPATIBILITY.md` | `pv 4` entry, negotiation note |
| `MacTests/` | new tests (§6) |

Note `Shared/` compiles into **all three** targets (`project.yml`), so
`AudioPlayer.swift` there must be Foundation/AVFoundation-only and macOS-12-safe.

---

## 6. Tests

The repo's test coverage is currently periphery-only — three of four test
files test the logger, and there is **no test on `MacSender`,
`StreamReceiver`, `Protocol`, or the wire path**. This feature should not
widen that gap, and most of what matters here is pure logic that needs no
hardware:

1. **`FrameCodecTests`** — round-trip every frame type; length arithmetic with
   the type byte; a payload that is exactly the old sniffing heuristic's blind
   spot (leading `{`, no NUL) survives tagging intact.
2. **`AudioPacketTests`** — header encode/decode round-trip; big-endian
   `ptsMs`; truncated/short header rejected without crashing.
3. **`ProtocolNegotiationTests`** — `pv 3` peer gets untagged, `pv 4` gets
   tagged; **untagged handshake before `pv` is known** (§2.2), including a
   handshake split across two TCP reads; latch resets on reconnect.
4. **`JitterBufferTests`** — underrun inserts silence, overrun drops oldest,
   reordering handled, bounded under sustained overrun.

All four are pure logic — no sockets, no CoreAudio, no display. They run in
the existing hostless `OpenSidecarMacTests` bundle with the sources compiled
straight in, exactly as `MacTests/DisplayArrangementTests.swift` does today.

Manual: USB and WiFi, both receivers, sleep/wake, reconnect, transport
migration mid-playback (`switchTransport`), and A/V sync against a
clapperboard-style visual+audio marker.

---

## 7. Phasing

Each phase is independently shippable and leaves `main` working.

* **Phase 1 — tagged frames, no audio. ✅ Done.** `pv 4`, both ends,
  negotiation, tests 1 and 3 (23 tests, green; all three targets build,
  receiver included at its macOS 12 floor). Pure tech-debt retirement: the
  sniffing heuristic now applies only to `pv <= 3` peers, no audio yet, no
  behaviour change on the wire for existing installs. `FrameType.audio` is
  defined and receivers skip it with a log — phase 2 fills it in.
* **Phase 2 — capture and send. ✅ Done.** SCK audio on the existing stream,
  AAC-LC encode, type-`2` frames; receiver parses, validates and counts.
  No playback yet — the whole path is verified with nothing audible to get
  wrong. 75 tests green, all three targets build. Audio is opt-in
  (`audioEnabled`, default off) and gated on the peer speaking `pv >= 4`.
* **Phase 3 — playback. ✅ Done.** Decode, jitter buffer, `AVAudioEngine`,
  both receivers, mute UI, buffer-health stats. 88 tests green, all three
  targets build. Audio is audible here — but nothing in this phase has been
  run against real hardware (§11).
* **Phase 4 — polish. ◐ Partly done.** What could be built without hardware
  is built: A/V skew measurement, an adaptive jitter buffer, and audio
  metrics in the perf overlay (94 tests green, all three targets build).
  What remains is *tuning*, and tuning without measurements is inventing
  numbers — so the rest waits on a real session (§11).

  **Done:** audio end-to-end latency computed with the same clock offset the
  video path uses, so the two are directly comparable; `avSkew` (audio
  latency − video latency) as the single number that says whether they are in
  sync; jitter-buffer target that grows on underruns, capped at
  `maxAdaptiveTarget` (~170 ms) and below capacity, forgotten on a new session
  but kept across a resume; `audio`, `A/V skew`, `buffer depth/target`,
  `a-under` and `a↓` in the overlay, and `aE2e50`/`avSkew`/`aTgt`/`aAdapt` in
  the 5 s wire report.

  **Waiting on hardware:** whether the 3-packet (~64 ms) starting target is
  right, whether skew sits inside ±40 ms (roughly the threshold where lipsync
  error becomes noticeable), whether the adaptation ceiling wants raising, and
  whether audio should lead or trail video by default. Every one of these is a
  number to read off a session, not a decision to make in advance.

Phase 1 shipping before Phase 2 is deliberate: it means a wire change and an
audio feature are never being debugged simultaneously.

---

## 8. The CoreAudio HAL driver (deferred, not dropped)

The original requirement named a CoreAudio virtual driver. Phase 1–3 deliver
working audio without one, which is why it is deferred rather than done first.
What a driver would add, and cost:

**Adds:** OpenDisplay appears as a selectable output device in Sound
preferences; per-app routing (send Spotify to the iPad, keep Slack on the
Mac); capture on macOS below 14, if the sender floor ever drops.

**Costs:** an `AudioServerPlugIn` bundle in `/Library/Audio/Plug-Ins/HAL`,
loaded by `coreaudiod` — a **separate, non-sandboxed process**. That means a
signed installer package and admin rights, replacing the current
drag-to-install DMG; Sparkle cannot update a HAL bundle in place; and a
`coreaudiod` restart on install. It is a distribution and support change more
than a coding one.

Worth doing when per-app routing is actually requested. Not worth blocking
audio on. If it does get built, it feeds the *same* type-`2` frames — the wire
format in §2.3 is capture-source agnostic, so the driver is a capture backend
swap behind an unchanged protocol, and nothing in phases 1–3 is wasted.

---

## 9. Open questions

Phases 1–3 shipped on the stated default for each. All five are still open in
the sense that any of them can be reversed — none is baked into the wire.

1. **iOS background audio.** Shipped as **no**: audio stops with video in
   `setRenderingPaused`, and the app claims no `audio` background mode.
   Reversing it means an `Info.plist` background mode and App Store review
   scrutiny. ~10 lines if wanted.
2. **Mix or duck other audio?** Shipped as `.mixWithOthers`
   (`OpenSidecarPhoneApp.configureAudioSession`), so plugging in a second
   display never silences someone's music. Reversible in one line.
3. **Default on or off?** Shipped **off**, opt-in via Stream audio on the
   sender. No existing install starts sending audio on update.
4. **Codec.** Shipped AAC-LC. The `codec` byte (§2.3) still reserves room for
   Opus without a wire break.
5. **Bitrate/quality tie-in.** Shipped fixed at 128 kbps, not tied to
   `StreamQuality`.

## 10. Main risks

* **Handshake ordering (§2.2)** — covered by phase 1's tests and shipped
  separately, as planned.
* **A/V sync drift** — one `SCStream` gives a shared capture clock and
  `clockOffsetMs` already exists. Unmeasured on hardware (§11).
* **`Shared/` deployment floor** — `AudioPlayer.swift` and
  `AudioJitterBuffer.swift` compile at macOS 12; CI builds the receiver to
  enforce it.
* **Audio starving video** — separate queues both ends, bounded buffer,
  drop-oldest under `pendingSends` pressure.

## 11. Not yet verified

Everything above is green in tests and builds on all three targets, but no
part of the audio path has run against real hardware from this environment.
Specifically unverified:

* that ScreenCaptureKit actually delivers audio buffers with
  `capturesAudio = true`,
* that `AVAudioConverter` encodes and decodes AAC-LC as wired here,
* that `AVAudioEngine` starts and plays on either receiver,
* that the jitter buffer's 3-packet target (~64 ms) is right in practice, and
* whether audio and video are perceptibly in sync.

**Step 1 — does the path work?** Switch on **Stream audio** on the Mac and
look for three log lines: `audio: encoding …` (sender), then
`audio: receiving …` and `audio: decoding …` (receiver). They separate
capture, transport, and decode, so whichever is missing localises the failure.

**Step 2 — read the numbers.** Turn on the performance overlay. With audio
flowing it gains `audio` (latency), `A/V skew`, and `buffer` (depth/target),
plus `a-under` and `a↓` if either is non-zero. The 5-second wire report
carries the same in the Mac's log: `aPkt`/`aKB`, `aDepth`/`aTgt`/`aAdapt`,
`aUnder`/`aDrop`/`aReord`, `aE2e50`/`avSkew`.

**Step 3 — decide the tuning from what they say.**

| Observation | Means | Action |
|---|---|---|
| `avSkew` within ±40 ms | in sync | nothing |
| `avSkew` strongly positive | audio trails picture | lower the starting target, or shorten the drain interval |
| `avSkew` negative | audio leads picture | raise the starting target |
| `aAdapt` climbing, `aUnder` persists | link jitterier than the ceiling allows | raise `maxAdaptiveTarget` |
| `aAdapt` 0, `aUnder` 0 | starting target is fine, maybe generous | try lowering `defaultTarget` to 2 |
| `aDrop` climbing | playback slower than arrivals | check the drain interval and engine health |

A clapperboard-style marker (a visible flash with a simultaneous click) is
still the ground truth for perceived sync; `avSkew` is the instrument that
says which direction to move and by how much.

---

## 12. Hardware bring-up: what was actually wrong

Every item below passed compile checks and unit tests. None was catchable
without a device, and each one hid the one after it.

| # | Fault | Symptom | Fix |
|---|---|---|---|
| 1 | Drain pulled 2 packets/10 ms (200/s) against ~47/s arrivals | continuous underruns, buffer never held | pace on the player node's queue depth |
| 2 | `ptsMs` from `CMSampleBuffer` presentation time (mach uptime) vs video's wall clock | `aE2e50` and `avSkew` stuck at 0 | stamp audio from the same wall clock |
| 3 | AAC `AudioSpecificConfig` never sent; `hasConfig` wired on neither side | decoder built, then rejected every frame | reconstruct the 2-byte cookie on the receiver |
| 4 | Encoder handed short SCK chunks to a converter needing 1024-sample frames | 6-byte stub packets on the wire | accumulate PCM, convert whole frames only |
| 5 | Decoder output buffer sized 2048 when one packet yields 1024 | `inputRanDry`, no PCM, **silence** | request exactly 1024 |

### What made it slow to find

**A total failure that logged nothing.** `inputRanDry` is not an error status,
so the `.error` branch never fired. A valid 401-byte AAC frame going in and no
audio coming out produced no diagnostic whatsoever. The fix that broke the
deadlock was not a code change but logging that case.

**Diagnosing a receiver-side fault from sender-side logs.** The Mac's counters
showed packets sent, none dropped — all true, all useless. The receiver's own
log named the cause in one line. `xcrun devicectl device process launch
--console <bundle-id>` reads it directly and should be the first step, not the
last.

**Two log directories.** The Debug build writes to `~/Library/Logs/OpenDisplay
Dev/` (keyed to `PRODUCT_NAME`), not `~/Library/Logs/OpenDisplay/`. Several
rounds of "audio never ran" were read from the release app's stale log.

### Environmental blockers, before any of the above

Three separate obstacles prevented audio from executing even once: the release
app (no audio code) was streaming instead of the dev build; TCC permissions
were keyed to a different bundle ID after rebranding for a personal team; and
the menu-bar icon was stranded off-screen at x≈11697 on a 2172-point desktop,
leaving the app's only UI unreachable. That last one is a real trap for a
virtual-display app — extending the desktop is what teaches macOS the far-right
position in the first place.
