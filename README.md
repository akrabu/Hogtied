# Hogtied 🐷

<img src="Assets/Hogtied.png" width="160" alt="Hogtied pig in a flat rope frame">

A small native macOS menu bar app that keeps selected memory hogs under control. It can also **log and notify when any readable process exceeds your limit**, without automatically quitting unwatched processes.

**Version 1.3.0 · macOS 13+ · 1 GB · every 5 minutes**

## Get started

Download the disk image for your Mac from [GitHub Releases](https://github.com/akrabu/Hogtied/releases). The DMG contains the app, an Applications shortcut, the matching optional administrator installer, and instructions. Quit any older running copy before replacing it. For ordinary installation, drag the app into Applications; for privileged mode, run the included helper installer instead. Open the installed app, then eject the disk image. Filenames identify the architecture: `arm64` for Apple silicon and `x86_64` for Intel.

1. Put **Hogtied.app** in `/Applications` and open it.
2. Add applications, select a running app, or enter an exact process name from Activity Monitor. An optional executable path distinguishes identically named processes.
3. Set the memory limit and interval, pressing **Apply** for each.
4. Choose **Quit mode → Only processes over the limit** to quit individual offenders while leaving smaller instances running. **Whole watched group** retains the original combined-memory behavior and remains the default for existing and new settings.
5. Enable **Automatically quit watched apps over the limit**, **Alert on any process over the limit**, or both.
6. Enable **Launch at login** to run Hogtied when you sign in. Any approval required by macOS is shown in the app.

Closing Settings leaves the pig in the menu bar. The menu provides both monitoring switches, Check now, Activity, Settings, and Quit. Enabling automatic quitting makes an immediate check. Adding or editing a target, changing limits, or resuming an entry updates the preview and leaves new enforcement to the next check. **Check now** enforces the limit only when automatic quitting is enabled and honors per-entry pauses.

Force-quitting can lose unsaved changes. Add only apps you want Hogtied to be allowed to force-quit.

## Quit mode

The **Quit mode** setting applies to all watched entries and to both local and administrator execution:

- **Whole watched group:** add the matching processes' footprints together, including helpers when selected. If the total exceeds the limit, quit the attributed group.
- **Only processes over the limit:** compare each matching PID separately. Signal only the processes whose own measured footprint exceeds the limit. Healthy same-name instances, parents, and helpers stay running. Unknown memory readings are never selected for termination. Helpers remain eligible only when **Include helper and child processes** is enabled.

For example, with a 512 MB limit and four matching processes at 600, 200, 100, and 50 MB, individual mode quits only the 600 MB process. At 350, 200, 100, and 50 MB, it quits none. In individual mode, the menu and watch list display **Max** for the largest process instead of a combined total; the Activity entry identifies the selected PID(s).

Changing quit mode takes effect at the next check and retains per-entry pauses. Retry limits still apply to each watched entry, with one batch of eligible individual offenders per check. During recovery verification, a pre-existing healthy sibling does not count as a healthy replacement for a signaled process. A newly measured replacement below the individual limit does, even when the whole group's combined footprint remains above the limit. Quitting an application process can also cause the application itself to shut down its helpers; Hogtied only sends signals to the selected PIDs in individual mode.

## All-process alerts and Activity

Alerts use the same limit and interval as watched entries and work with an empty watch list or while automatic quitting is paused. Each process is measured separately. One alert is logged per over-limit spike; a healthy reading or confirmed exit re-arms it. PID plus process start time distinguish restarted processes. An unreadable measurement does not mean the process recovered.

Hogtied asks for local notification permission when alerts are enabled. If permission is denied, alerts still appear in Activity. Enable notifications later in **System Settings → Notifications → Hogtied**. Clicking a notification opens the corresponding Activity entry if it remains in the recent history.

Activity keeps the latest 100 alerts, quit attempts, recoveries, pauses, and resumes locally. **Watch this process** adds the logged process directly to the watch list, pinning its executable path when available. Existing matches show **Already watched**; adding a target does not immediately quit it. Protected processes remain alert-only with an explanation.

The app displays how many visible processes could be measured. Some process memory remains unavailable without the optional administrator helper, and macOS may protect some measurements even with it. An incomplete process listing is explicitly reported rather than treated as proof that missing processes exited.

## Recovery, retries, and cooldown

A service restarting at normal memory usage is expected and counts as successful recovery.

- **Maximum quit attempts** defaults to **3**, configurable from 1 to 100. One watched group gets at most one attempt per check; signaling several attributed helper processes still belongs to that single attempt.
- After an attempt, Hogtied observes recovery for up to two seconds. A measured return below the limit resets the failure count. A surviving process or replacement still over the limit counts as a failed recovery.
- If a process exits before its replacement appears, recovery remains pending until the next enforcement check. An over-limit replacement without an intervening healthy observation continues the same incident. A later leak after observed recovery starts a new incident.
- Unreadable recovery memory leaves the outcome pending. Protected-process skips, missing privileges before a signal can be attempted, stale process identities, canceled checks, and connection errors do not consume retries. A denied signal that is actually attempted can count if the target remains over the limit.
- An entry exhausting its attempts pauses independently. Other watchers and all-process alerts continue. Pauses and failure counts survive app restarts and global monitoring toggles.
- **Resume** clears the entry's count and makes it eligible at the next check. By default, resume is manual.
- Optionally enable automatic resume after a cooldown, initially **30 minutes**, configurable from 1 to 1,440 minutes. The deadline is calculated from the saved pause time; edited durations apply to existing pauses. At the next check after expiry, the count resets and the entry becomes eligible again. Disabling automatic resume leaves paused entries paused.

Checks require an awake Mac and a running Hogtied app. Waking triggers a new check when monitoring is active.

## Optional administrator helper

Ordinary mode can quit the signed-in user's processes. The optional helper also permits eligible third-party root-owned processes and improves read-only process visibility.

1. Quit any older copy of Hogtied or Memory Hog Killer.
2. Open **Hogtied Admin Helper.pkg** and complete the standard macOS Installer flow. It installs the matching app into `/Applications` and asks for administrator authentication for the helper.
3. Open the installed Hogtied app, then enable **Use administrator helper** under **System process access**.
4. Add exact process names/paths and enable the desired monitoring switches.

The installer binds the helper to the signed-in account and the exact signed app version in the package. **Reinstall the matching helper package after updating or rebuilding the app.** An old or mismatched helper is not used. Installation does not enable monitoring or the helper-use switch.

The helper accepts only the pinned app identity over XPC. It remeasures processes itself, checks the current policy before signaling, verifies process identity and executable path, protects the controller/helper, and excludes built-in macOS root services and other users' processes from termination. All-process inventory can be broader than termination eligibility. It has no shell-command or file-management interface. Both local and administrator execution use the same recovery engine.

**Uninstall helper…** opens the included removal script, which asks for administrator authentication and removes the helper's service and files. The app and preferences remain.

The supplied app uses ad hoc signing for local use. The installer is not Developer ID signed or notarized. Public redistribution of a trusted downloadable binary should use an appropriate Apple Developer ID and notarization; building from this source uses your local toolchain.

## Upgrading from Memory Hog Killer

Hogtied retains `local.memoryhogkiller.app`, the existing preference domain, and the helper's service/trust locations for compatibility. Watch entries, prior settings, and old activity records are preserved; the new alert switch and automatic cooldown default to off. Startup registration is refreshed for the renamed app when previously enabled. Review its status after moving the app.

Replace the older application with Hogtied and use the matching 1.3.0 administrator installer if you use privileged mode. Keep a single running controller. Upgrading from 1.2.0 preserves your watch list, limit, interval, monitoring switches, cooldown, history, and paused entries; select individual-process mode explicitly if desired.

## Memory accounting and matching

Hogtied uses physical memory footprint (`ri_phys_footprint`), which includes compressed memory accounting and can differ from resident size or Activity Monitor's display.

Names match completely and without regard to capitalization. `Safari` and `Safari.app` match; partial names and wildcards do not. Chosen application bundles match by bundle identifier. Process entries can match exact executable names and optionally pin an absolute executable path.

Watched entries attribute matching main processes and, when enabled, executables in their bundles and descendants. Separate foreground applications are excluded from helper attribution. Whole-group mode sums these processes; individual mode compares each footprint separately. Shared memory can be counted more than once when footprints are summed. All-process alerts always measure individual processes, regardless of quit mode.

The threshold is strictly greater than the configured amount: exactly 1 GB does not exceed a 1 GB limit. A GB is 1,000,000,000 bytes. Limits accept 1 MB to 1,000 GB; intervals accept whole seconds from 5 seconds to 24 hours.

Settings, recent activity, retry state, and active spikes are stored locally using UserDefaults. The app has no telemetry or cloud service. Notifications use macOS's local notification system.

## Build and check

Requires macOS 13 or later and Apple's Command Line Tools with Swift 5.9 or newer. Building on Apple silicon produces an arm64 app; building on Intel produces an Intel app.

```sh
./Scripts/test.sh
./Scripts/build.sh dist
./Scripts/package-admin.sh dist/Hogtied.app dist
./Scripts/package-dmg.sh dist/Hogtied.app dist
open dist/Hogtied.app
```

Use `HOGTIED_BUILD_DIR` to choose a scratch directory; the older `MHK_BUILD_DIR` variable remains supported. The scripts use SwiftPM's native build system to support Command Line Tools without a full Xcode installation. macOS CI runs the checks, builds the app, matching helper package, and verified DMG, and uploads the resulting artifacts. DMG filenames include the app version and architecture.

Tests cover migration, both quit modes, matching and helper attribution, spike suppression/re-arming, notification denial policy, process promotion, retry budgets, healthy restarts, unhealthy relaunches, cooldowns, cancellation, and protected targets. Native integration checks inspect process metadata and authenticated XPC, reject outdated protocol requests, and terminate only disposable processes created by the tests. Same-executable sibling tests verify individual mode in local and helper execution. Run them outside a restrictive command sandbox; restricted process discovery or XPC will otherwise cause those checks to fail.

Source layout:

- `Sources/HogCore`: settings, matching, inventory, memory accounting, spike/retry state, shared check engine, and termination guards.
- `Sources/HogIPC`: versioned XPC protocol, pinned identities, and administrator worker.
- `Sources/Hogtied`: menu bar lifecycle, SwiftUI controls, persistence, notifications, login registration, helper client, and template icon.
- `Sources/HogtiedHelper`: authenticated launchd service entry point.
- `Assets`: approved icon and app/helper manifests.
- `Checks`: deterministic policy tests and native disposable-process integration checks.
- `Scripts`: app/icon builds and optional helper packaging/uninstallation.
