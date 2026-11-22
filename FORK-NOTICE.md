# Fork notice

This is an unofficial fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux).
It is not affiliated with or endorsed by Manaflow, Inc. "cmux" is Manaflow's name.

## What this fork contains

The `tl/*` branches contain modifications made by Michael Turquette in
November 2026 (local tmux mirroring without SSH, its test harness, and related
fixes). The default branch `main` is upstream's code, unmodified.

These modifications are licensed under GPL-3.0-or-later, the same license as
the upstream app. All upstream copyright and license notices are kept as they
were. The Business Source License directories (`web/`, `workers/`,
`services/iroh-relay-minter/`, `cmux-tui/relays/cloudflare-do/`) are not
modified.

This repository is a source-only backup. No compiled builds are published.

## Files modified on the tl/* branches

Each file below was modified by Michael Turquette in November 2026. The git
history of each branch records the exact change and date.

- `CLI/cmux.swift`
- `CLI/CMUXCLI+TmuxMirror.swift`
- `CLI/Commands/CmuxCommand.swift`
- `CLI/Commands/SystemCommands.swift`
- `CLI/LocalTmuxInvocation.swift`
- `CLI/TmuxMirrorInvocation.swift`
- `CLI/TmuxMirrorStartDirectory.swift`
- `CLI/TmuxServerSocketResolver.swift`
- `cmux.xcodeproj/project.pbxproj`
- `cmuxCLITests/TmuxMirrorInvocationTests.swift`
- `cmuxCLITests/TmuxMirrorStartDirectoryTests.swift`
- `cmuxCLITests/TmuxServerSocketResolverTests.swift`
- `cmuxTests/MainWindowVisibilityControllerTests.swift`
- `cmuxTests/RemoteTmuxConnectionLatestClientSizingTests.swift`
- `cmuxTests/RemoteTmuxConnectionWakeRecoveryTests.swift`
- `cmuxTests/RemoteTmuxLocalMirrorLinkTests.swift`
- `cmuxTests/RemoteTmuxLocalMixedReleaseTests.swift`
- `cmuxTests/RemoteTmuxLocalParserFuzzTests.swift`
- `cmuxTests/RemoteTmuxLocalPseudoTerminalTests.swift`
- `cmuxTests/RemoteTmuxLocalServerBinaryTests.swift`
- `cmuxTests/RemoteTmuxLocalSocketBoundaryTests.swift`
- `cmuxTests/RemoteTmuxLocalTransportProfileTests.swift`
- `cmuxTests/RemoteTmuxMirrorNewTabStartingInputTests.swift`
- `cmuxTests/RemoteTmuxMirrorScrollerGutterAppTests.swift`
- `cmuxTests/RemoteTmuxOneShotProfileRoutingTests.swift`
- `cmuxTests/RemoteTmuxScreenUnlockGateTests.swift`
- `cmuxTests/RemoteTmuxSessionChannelTests.swift`
- `cmuxTests/RemoteTmuxSSHTransportWakeRenewalTests.swift`
- `cmuxTests/RemoteTmuxWakeRecoveryCoordinatorTests.swift`
- `cmuxTests/TerminalAppActivationObserverTests.swift`
- `docs/cli-command-tree.txt`
- `docs/cli-contract.md`
- `docs/remote-tmux-transport-seam.md`
- `Packages/macOS/CmuxRemoteSession/Sources/CmuxRemoteSession/RemoteTmux/Layout/RemoteTmuxMirrorGeometry.swift`
- `Packages/macOS/CmuxRemoteSession/Sources/CmuxRemoteSession/RemoteTmux/Layout/RemoteTmuxNativeLayoutMetrics.swift`
- `Packages/macOS/CmuxRemoteSession/Sources/CmuxRemoteSession/RemoteTmux/RemoteTmuxClientRoster.swift`
- `Packages/macOS/CmuxRemoteSession/Tests/CmuxRemoteSessionTests/RemoteTmuxClientRosterTests.swift`
- `Packages/macOS/CmuxRemoteSession/Tests/CmuxRemoteSessionTests/RemoteTmuxMirrorScrollerGutterTests.swift`
- `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift`
- `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalUserActivation.swift`
- `Packages/macOS/CmuxTerminal/Tests/CmuxTerminalTests/TerminalUserActivationTests.swift`
- `Resources/Localizable.xcstrings`
- `scripts/lint-remote-tmux-no-polling.sh`
- `scripts/remote_tmux_local/bench.py`
- `scripts/remote_tmux_local/conformance.py`
- `scripts/remote_tmux_local/harness.py`
- `scripts/remote_tmux_local/REQUIREMENTS.md`
- `scripts/remote-tmux-local-adversarial-lib.sh`
- `scripts/remote-tmux-local-adversarial.sh`
- `scripts/remote-tmux-local-bench.sh`
- `scripts/remote-tmux-local-conformance.sh`
- `scripts/remote-tmux-local-leak-check.sh`
- `Sources/App/MainWindowVisibilityController.swift`
- `Sources/AppDelegate+RemoteSessionPower.swift`
- `Sources/CommandClickFileOpenRouter.swift`
- `Sources/GhosttyNSView+ClipboardActions.swift`
- `Sources/GhosttyNSView+DirectUserInput.swift`
- `Sources/GhosttyTerminalView.swift`
- `Sources/RemoteTmuxControlConnection.swift`
- `Sources/RemoteTmuxControlConnection+LatestClientSizing.swift`
- `Sources/RemoteTmuxControlConnection+PaneSubscriptions.swift`
- `Sources/RemoteTmuxControlConnection+Sizing.swift`
- `Sources/RemoteTmuxControlConnection+WakeRecovery.swift`
- `Sources/RemoteTmuxController.swift`
- `Sources/RemoteTmuxController+Attach.swift`
- `Sources/RemoteTmuxController+Decisions.swift`
- `Sources/RemoteTmuxController+Multiplexer.swift`
- `Sources/RemoteTmuxController+NewSession.swift`
- `Sources/RemoteTmuxController+StartingInput.swift`
- `Sources/RemoteTmuxController+WakeRecovery.swift`
- `Sources/RemoteTmuxControlPipeWriter.swift`
- `Sources/RemoteTmuxError.swift`
- `Sources/RemoteTmuxHost.swift`
- `Sources/RemoteTmuxLiveWakeRecoveryEnvironment.swift`
- `Sources/RemoteTmuxLocalPseudoTerminal.swift`
- `Sources/RemoteTmuxLocalServerBinary.swift`
- `Sources/RemoteTmuxLocalServerSocket.swift`
- `Sources/RemoteTmuxLocalTransportProfile.swift`
- `Sources/RemoteTmuxProcessOutputReader.swift`
- `Sources/RemoteTmuxScreenUnlockGate.swift`
- `Sources/RemoteTmuxSessionChannel.swift`
- `Sources/RemoteTmuxSessionMirror+WindowReconciliation.swift`
- `Sources/RemoteTmuxSessionSource.swift`
- `Sources/RemoteTmuxSSHTransport.swift`
- `Sources/RemoteTmuxSSHTransport+WakeRenewal.swift`
- `Sources/RemoteTmuxTransportRegistry.swift`
- `Sources/RemoteTmuxViewConnection.swift`
- `Sources/RemoteTmuxWakeHostGroup.swift`
- `Sources/RemoteTmuxWakeRecoverableStream.swift`
- `Sources/RemoteTmuxWakeRecovery.swift`
- `Sources/RemoteTmuxWakeRecoveryCoordinator.swift`
- `Sources/RemoteTmuxWakeRecoveryEnvironment.swift`
- `Sources/RemoteTmuxWakeRenewalResult.swift`
- `Sources/RemoteTmuxWakeStreamPhase.swift`
- `Sources/RemoteTmuxWindowMirror+BonsplitLayout.swift`
- `Sources/RemoteTmuxWindowMirror+SizingTransaction.swift`
- `Sources/TerminalAppActivationObserver.swift`
- `Sources/TerminalController+ControlSurfaceContext2.swift`
- `Sources/TerminalController+RemoteTmux.swift`
- `Sources/TerminalController+RemoteTmuxControlMutations.swift`
- `Sources/TerminalController+RemoteTmuxLocal.swift`
- `Sources/Workspace.swift`
- `Sources/Workspace+RemoteTmuxControlTopology.swift`
