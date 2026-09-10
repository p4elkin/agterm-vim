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

## Options, none taken

The fix belongs upstream and none of it is the fork's to choose:

- have the fixture copy the x86_64 slice only (`lipo -extract x86_64`), which keeps `nc` and costs Rosetta;
- build a tiny client target instead of borrowing `nc`, which removes the platform-binary problem entirely;
- take the client from Homebrew's netcat rather than `/usr/bin/nc`.

Worth reporting upstream before touching anything here. Editing an upstream test in the fork is a merge
conflict every time that file changes, for a suite the fork has no stake in.
