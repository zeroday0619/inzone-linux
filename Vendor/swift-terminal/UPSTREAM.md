# Upstream source

This directory contains the `Terminal` sources from
[minacle/swift-terminal 0.0.2](https://github.com/minacle/swift-terminal/tree/645d429e6158d226c4b82f8ca5bf91c2a9e9c4b1),
commit `645d429e6158d226c4b82f8ca5bf91c2a9e9c4b1`.
SwiftTUI 0.12.0 requires this package version.

The local change imports Darwin/Glibc before System/SystemPackage in
`Terminal+size.swift`. Swift 6.3.3 on Linux otherwise attributes `winsize`
members to the transitive CSystem module and rejects their use under
`MemberImportVisibility`. The source order change retains all upstream
compiler checks and avoids importing a private transitive module.

SwiftPM 6.3.3 emits a dependency identity warning for the local override of
the transitive remote package. Both products build with this override.
When upstream SwiftTUI adopts a terminal release containing the fix,
remove the local override and this snapshot together.

The package manifest omits the upstream test target because its tests are
not included in this source snapshot. INZONE terminal tests exercise the
resulting terminal dimensions, rendering, and keyboard input.
