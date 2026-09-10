---
worth: later
where: agtermCore/Tests/SessionHostRuntimeTests/SessionHostServerTests.swift:441
added: 2026-09-10
---
# the session-host fixture's copied nc is SIGKILLed on Apple Silicon

`SessionHostServerTests.Fixture` builds a fake `Test.app` under `/tmp` and needs a client inside that
bundle so the host's peer check resolves the same bundle identity. It gets one by copying `/usr/bin/nc`
to `Contents/MacOS/test-client` and ad-hoc re-signing it.

`/usr/bin/nc` is a universal `x86_64 arm64e` platform binary. Ad-hoc signing strips its platform status
while leaving the arm64e slice in place, and macOS prefers that slice on an Apple Silicon Mac. AMFI then
kills it on exec, because arm64e is reserved for platform binaries. So `Fixture.raw` gets no output at
all, every `exchange` returns an empty array, and six tests fail — five on
`exchange(.stop).last == .stopped`, one on `guard case .ok` for the ensure.

This is upstream's test code, byte-identical to `umputun/agterm` at `6305191`; the fork contributes
nothing to it. It arrived in the fork with the v0.28.0 merge and fails every `swift test` run since.

## What happened

Witnessed on p4studio (arm64, macOS 26) on 2026-09-10, running
`swift test --filter 'SessionHostServerTests/hostSocketIsNotEnumeratedByStockZmx'`:

1. `Fixture.start()` succeeds. The host writes its pidfile — observed as `54332` in
   `/tmp/shs-BF696159-.../zmx/session-host/session-host.pid`, matching the `54332` in `ps`, with the
   socket bound beside it. So the disclaimed spawn, the bundle identity check and the listener are all
   fine.
2. `fixture.list()` succeeds — that shells out to the staged `zmx`, a normal signed binary.
3. `fixture.exchange(.stop)` runs `Test.app/Contents/MacOS/test-client -U <socket>`. That process is
   killed immediately. Reproduced by hand: running the copied binary prints nothing and exits **137**,
   which is 128+9, SIGKILL. The same copy run as `arch -x86_64 <copy> -h` prints nc's usage and exits 0,
   so the x86_64 slice under Rosetta is fine and only the arm64e slice is refused.
4. `exchange` therefore returns `[]`, `#expect(... .last == .stopped)` fails, the host is never told to
   stop, and `waitForExit()` throws `ETIMEDOUT` five seconds later — the two issues each test reports.

Reproduces with the tool sandbox off and with a single-test filter, so it is neither sandboxing nor
parallel-test contention.

## Reported and fixed upstream

- Issue: https://github.com/umputun/agterm/issues/577
- PR: https://github.com/umputun/agterm/pull/578 — adds a small `session-host-test-client` executable
  target, not a package product, and copies that into the test bundle instead of `nc`. Verified locally:
  22 tests pass in 3.3s where six failed, full `swift test` green, swiftlint clean.

⚠️ **Do not patch the fixture in this fork while that PR is open.** A fork edit inside an upstream test
file is a merge conflict every time upstream touches it, for a suite the fork has no stake in. Until the
PR lands, the six failures are expected on every `swift test` here.

`git rm` this item when the fix arrives in a merge from upstream.
