# Controlling the phone from the Mac receiver

Notes from a spike into whether the Mac receiver can drive a broadcasting
iPhone as a pointer and keyboard. Written down because two of the three dead
ends look plausible enough to try again.

## What shipped

Session control, over the existing `pv 4` wire: the receiver can stop, pause,
and resume the sender's broadcast (`WireMessage.stopBroadcast` and friends).
Verified on hardware — every command logged on the Mac and acted on inside
the broadcast extension 37-95 ms later.

That is the useful half of "operate the phone from the Mac", and it is the
only half that works today.

## What does not work, and why

### Injecting touches over our own wire

The wire can carry touch coordinates — it already does, in the Mac-sender
direction. The extension receives them and discards them:

```swift
case "touch", "scroll":
    break   // view-only mirror: iOS offers no event injection
```

iOS has no API to synthesise an event into another app. Not a transport
problem, so no amount of protocol work fixes it: a faster socket still
arrives at a process that cannot deliver the event. `UIEvent` has no public
injection path, `IOHIDEventSystemClient` event posting needs an entitlement
Apple does not grant, and a broadcast extension is sandboxed more tightly
than the host app.

The pattern that does work over the wire: our control messages ask the
sender app to act **on itself**. Pause, resume, stop, keyframe, bitrate,
clipboard, `openURL` — all fine. Commanding the OS to act on *other* apps is
the line.

### BLE HID (Bluetooth Low Energy, HID-over-GATT)

The idea: don't be an app injecting events, be a Bluetooth mouse. Events
then enter below the app layer, where iOS accepts them by design (via
AssistiveTouch for a pointer on iPhone).

macOS refuses to publish the service. Measured, one service per run:

```
OK    custom 128-bit (6E400001-...)
OK    custom 16-bit  (FFF0)
BLOCK HID (0x1812):        The specified UUID is not allowed for this operation.
BLOCK Battery (0x180F), DeviceInfo (0x180A), GAP (0x1800), GATT (0x1801)
```

Every SIG-assigned UUID is reserved for the system stack; custom UUIDs are
fine. Publishing a keyboard under a custom UUID is pointless — a host binds
HID by the standard UUID, and anything else is an app-defined service the
phone has no reason to treat as input.

This one is a genuine dead end.

### Classic Bluetooth HID (L2CAP + SDP) — unresolved, not disproven

The idea: the classic HID device role, via IOBluetooth rather than
CoreBluetooth. Unlike GATT, none of the pieces are deprecated or obviously
blocked, and the transport registers fine:

```
OK  registered for incoming L2CAP PSM 0x11 (control)
OK  registered for incoming L2CAP PSM 0x13 (interrupt)
OK  published SDP service record, handle 0x4f491124   (minimal record)
```

Twelve consecutive minimal-record publishes succeeded, so there is no leak
or per-process limit.

**This path is known to be achievable.** KeyPad (`com.toolbunch.keypad`,
<https://bluetooth-keyboard.com>) is a 375 KB sandboxed Mac App Store app,
shipping since 2020, that presents a Mac as a Bluetooth keyboard and mouse
to iPhone and iPad. App Store review forbids private frameworks, so it is
doing this with the same public API this spike used. Its setup is described
as "making KeyPad discoverable, pairing and connecting over Bluetooth",
which lines up with `setClassOfDevice:forTimeInterval:` — deliberately
temporary (30-120 s, backed by `_cachedClassOfDevice` and
`_timerClassOfDeviceSetting`), i.e. a pairing window rather than a
persistent identity change.

What stopped the spike was the method, not the platform. Publishing richer
HID SDP records **crashes `bluetoothd`** — 14+ reports, `EXC_CRASH SIGABRT`,
`Abort trap: 6`, aborting inside the daemon while handling the XPC message
from the publishing process. Causally confirmed: healthy daemon, publish
once, one new crash report. After enough crashes launchd throttles the
daemon (`state = spawn scheduled`, `runs = 17`) and it stops coming back,
taking Bluetooth down machine-wide until a `sudo launchctl kickstart -k
system/com.apple.bluetoothd` or a reboot.

That instability invalidated most of the attribute-level results. A brute
bisect produced a clean-looking boundary at attribute `0202` that did not
survive re-testing: attributes failed in sequence but passed alone, then
everything failed including records that had just worked, because the runs
were measuring a dead daemon rather than the records. A "canary publish"
health check was not sufficient either — it passed while real publishes
failed.

One thing survived re-testing: a failure poisons the rest of the process.
After the first nil return, later publishes in the same process fail
regardless of content, so every test needs a fresh process per case.

### Second attempt, with a crash budget

A follow-up run used a harness that refuses to publish unless `bluetoothd`
has been up for 20+ seconds, counts crash reports around every attempt, and
halts the session after three. Crash reports stayed at 19 throughout, so
every result below is a clean rejection rather than an abort — the first
trustworthy attribute data from either attempt.

It also overturned the earlier encoding claim. Explicit
`DataElementType`/`Size`/`Value` dictionaries return nil for *every* record
including the minimal one, while the shorthand form (nested `NSArray` =
sequence, `Data` = UUID or blob, `String` = text) publishes. The earlier
"explicit elements work" result was a daemon artifact. Shorthand is what the
API wants.

With each test preceded by a passing control publish:

| record | result |
| --- | --- |
| core (service class, protocol list, browse group, language base, profile descriptor, additional protocol list, names) | OK |
| core + version attributes (`0200`, `0201`, `020B`, all 2-byte `Data`) | OK |
| core + flag attributes (`0202`-`0205`, `020C`-`020F`; `Bool` and 1-byte `Data`) | nil |
| core + descriptor list (`0206`, `0207`) | nil |

So a full HID-shaped record publishes right up to the point where it needs
the attributes that make it a *keyboard* — the boot flags and the report
descriptor.

### Third attempt: the crash trigger, identified

A run isolating one value kind per process found it. Testing the *same*
attribute (`0202`) with different value encodings:

| value | result |
| --- | --- |
| `true` (Swift `Bool`) | OK |
| `NSNumber(value: true)` | OK |
| `NSNumber(value: 1)` | OK |
| `Data([0x40])` — one byte | **crashes `bluetoothd`** |
| `Data([0x00, 0x40])` — two bytes | OK |
| `Data([0x0C, 0x80])` on `020C` | OK |

**A one-byte `Data` value crashes the daemon.** Not a rejection — an abort,
confirmed by the crash-report count rising across the attempt while the
two-byte form of the same attribute publishes cleanly. `Bool` was never the
problem; the earlier "flags are rejected" result was one bad byte in a group
of eight attributes.

This is the root cause of every crash in this spike, including the ones that
invalidated the first attempt's bisection. Every HID attribute the spec
defines as a single byte — `0202` HIDDeviceSubclass, `0203` HIDCountryCode,
and the `0x22` descriptor-type tag inside `0206` — hits it.

`0206 - HIDDescriptorList` crashes for the same reason: its inner sequence
starts with `Data([0x22])`, a one-byte value.

That leaves one thing to find: how to express a single-byte unsigned integer
so this API encodes it safely. `NSNumber` works for a bool-typed attribute,
so the likely answer is `NSNumber` for the integer-typed ones too, with the
element size left to the framework. Untested — the daemon went down before
that run.

The harness itself is worth reusing — it caught the dead daemon immediately
and cost nothing, where the first attempt spent dozens of runs measuring one.

`IOBluetoothHostController.classOfDevice()` reads `0x0` on this machine no
matter what is set, so it cannot be used to verify the setter. The only
meaningful verdict is whether a phone lists the Mac in its Bluetooth
settings — which this spike never got to.

## If someone picks this up again

Start from the shorthand encoding and the core record above, which is known
to publish, and never put a one-byte `Data` in a record — that is the crash.
The open question is how to express a single-byte unsigned integer instead;
try `NSNumber(value: 0x40)` for `0202` first, since `NSNumber` already works
for the bool-typed attributes.

Keep the crash-budget harness, with one fix: its staleness gate rejects a
daemon under 20 seconds old, which reads identically to "daemon unhealthy"
in the output and cost a round of confusion. Distinguish the two.

The daemon is the fragile part — losing it costs the machine's Bluetooth,
not just the test — and it can go down without producing a crash report, so
a passing control publish immediately before each result is the only way to
trust that result. Recovery is automatic but slow, and launchd throttles it
after enough restarts; `sudo launchctl kickstart -k system/com.apple.bluetoothd`
forces it back.

Worth knowing before starting: even when it works, iPhone gets pointer
control only with AssistiveTouch enabled by the user (iPad gets a native
cursor). Keyboard needs no such setup. Any pairing is also out-of-band —
it has nothing to do with our wire protocol and works whether or not a
broadcast is running, so it would be a separate feature rather than an
extension of mirroring.

## Ranking, corrected

The order tried was wrong twice. BLE was tried first and is the one path
that is definitively blocked; classic Bluetooth was written off second and
is the one that a shipping App Store app proves is possible.
