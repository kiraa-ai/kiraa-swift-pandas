# Design: a CI lane that actually runs `MetalMergeTests` (#27, secondary)

## State what the issue is

Both tests that catch the #27 race (`testInnerJoinDuplicateKeys`, `testInnerJoinCorrectness`) predate the report and fail today — yet nothing ever ran them automatically.

Context on the issue's framing: the bug was hit downstream, in a repo that imports SwiftPandas as a package. SPM never builds or runs a dependency's test targets, and a binary consumer (`SWIFTPANDAS_USE_BINARY=1`) doesn't even have them in its package graph — so from that vantage "the tests never run" is accurate. Within *this* repo, though, binary mode is strictly opt-in (`Package.swift:52`, `== "1"`) and a plain `swift test` builds from source and runs `MetalMergeTests` — which fail today. The gap is that nothing does so automatically: the repo's only workflow is `.github/workflows/release.yml`, which just updates the Homebrew tap. This repo is the only place these tests can ever execute, and there is **no CI that builds or tests anything**.

We are designing the test lane that closes that gap. Constraint: Metal tests assert `MetalDispatch.isAvailable` and expect a Metal-capable Mac, so the runner choice is the design decision.

## Code in question

- `.github/workflows/` — contains only `release.yml`; no build/test workflow exists (this is the gap, not a bug in a file).
- `Package.swift:50-52` — binary consumption is opt-in via `SWIFTPANDAS_USE_BINARY=1`; CI must simply not set it.
- `Tests/SwiftPandasTests/MetalTests.swift:398-488` — the merge tests a lane must execute.

## Proposed Design 1 — GitHub-hosted Apple-silicon runner

BEFORE: no test workflow.

AFTER: new file `.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: macos-15   # Apple-silicon hosted runner
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: swift build
      - name: Test
        run: swift test
```

GitHub's arm64 macOS runners virtualize a paravirtual GPU that exposes Metal, so `MetalDispatch.isAvailable` is expected to hold — but that must be verified with a probe run before relying on the lane (if the VM's Metal support turns out incomplete for compute, the lane would fail on runner capability rather than on code). Zero infrastructure to maintain; runs on every PR, which is the property that would have caught #27.

## Proposed Design 2 — self-hosted runner on a maintainer Mac

BEFORE: no test workflow.

AFTER: the same `ci.yml` with `runs-on: [self-hosted, macOS, ARM64]`, plus a registered runner on real Apple hardware (the same class of machine `scripts/build-release.sh` already assumes).

Guaranteed real Metal — the test environment matches the production environment exactly, including GPU timing characteristics that make the #27 race reproduce. Costs: a machine that must stay online, runner maintenance, and security exposure if the repo ever accepts outside PRs (self-hosted runners execute PR code on the maintainer's hardware).

## Recommendation

**Design 1.** A hosted runner needs no infrastructure and runs on every PR, and the probe run either validates it immediately or fails loudly on the first day — nothing silent. Design 2's only advantage (bare-metal GPU fidelity) matters for performance work, not for correctness tests like the two that catch #27; its maintenance and security costs are permanent. If the probe run shows the hosted VM cannot run the Metal compute kernels, that result comes back to this PR and Design 2 becomes the fallback conversation.

## Next steps

Same gating as the main design doc: this lane gets built only after the design is locked in review. The probe run (a throwaway branch pushing `ci.yml` and observing whether the Metal tests execute rather than skip or crash) is the first implementation step.
