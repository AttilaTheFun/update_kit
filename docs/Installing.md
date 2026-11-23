# Installing a sandboxed app's update (UpdateKitInstall)

A sandboxed Mac app can't put its own update in place. macOS quarantines
what a sandboxed process writes (and what any child it spawns writes, ditto
included), so an app unpacked by one is translocated when it opens, and its
launch fails (`EPERM`, `-10810`, "this application can't be opened"). The
same zip, unpacked by an unsandboxed process with `ditto --noqtn`, opens.

So a sandboxed app that installs builds (Applications installing the apps
it distributes, or an app installing its own update) does it in two halves:

- **The app** downloads the build into a folder it can write, its sandbox
  container or an app group's container, and asks its installer service to
  install it, with the bundle id, the name and the SHA-256 its release lists.
- **The installer service**, an XPC service embedded in the app and not
  sandboxed (allowed with Developer ID), checks the build and puts it in
  place: `BundleInstall`, with `MacBundleInstallSystem` for the Mac. The
  rules are portable and run in the tests on Linux too.

## The rules

`BundleInstall.install(_:policy:system:)`, in order, each refusing with an
`InstallRefusal` (a stable `code` to phrase it by, and a plain `reason`),
with nothing after it done:

1. the bundle id is the policy's: `bundleIDPrefix` itself, or it followed
   by a dot and more;
2. the name is a plain file name, so `<applications>/<name>.app` is in the
   applications folder;
3. the zip, its links resolved, is a file inside one of the policy's
   `zipFolders` (never reached through a link out of them: a container's
   Downloads is a link to the user's);
4. it is copied, its bytes alone, into a fresh folder of the service's own,
   and the copy's SHA-256 is the one given. Only the copy is used from here
   on, so the app can't change the file between the check and the
   unpacking;
5. the copy, unpacked there by `ditto -x -k --noqtn` within the policy's
   `unpackTimeLimit` (five minutes by default; a stuck ditto is stopped),
   holds exactly one app, of that bundle id;
6. its signature passes: valid (strict, every architecture, nested code),
   signed by the service's own team, and with that team's Developer ID
   Application certificate and notarized wherever the app around the
   service is. A service with no team (an ad hoc test build) installs only
   builds with no team, so the whole path can run in a test VM;
7. what is at the destination already is that app (or one of its
   `earlierIDSuffixes` ids), or nothing.

Then any quarantine left is removed, the new bundle is swapped into place in
one rename (`renamex_np`'s `RENAME_SWAP`), and it is registered with
LaunchServices. A refusal before the swap leaves the applications folder as
it was.

## The backup

The copy an install replaced stays in the service's folder, unregistered
from LaunchServices, as `InstallResult.backup`, with the SHA-256 of the
new build's main executable (`executableSHA256`):

- `BundleInstall.discard(backup:system:)` once the new build has stayed
  up: removed, unless a process still runs from it (an app that updated
  itself, until it has quit), when a later install sweeps it;
- `BundleInstall.restore(backup:destination:installedExecutableSHA256:bundleID:policy:system:)`
  when it hasn't: the backup swapped back, refused unless the backup is
  still the service's own, a whole app of that bundle id that passes the
  signature check, and the build in place is still the one the install put
  there (its executable's SHA-256), so a later update or the person's own
  change is never undone;
- one neither discarded nor restored, that nothing runs from, is swept by
  an install after the policy's `backupLifetime` (a day by default).

## Staying up

Once the new build is in place, the app asks its service to watch it
(`StayUpWatch`) and quits. The service can't do the watching itself, since
launchd ends it with the app. So `StayUpWatchLauncher.start` copies the
service's own bundle into the service's folder (a copied bundle stays
validly signed, and the build in place can change under it) and starts a
one-shot launchd job of the user's (`gui/<uid>`, `AbandonProcessGroup`)
that runs the copy in watch mode. The service's `main` calls
`StayUpWatchLauncher.runIfAsked()` first, before its listener. The
watcher (`StayUpWatcher`):

1. takes the lock (`WatchLock`): a file holding `<pid> <started-epoch-seconds>`,
   which counts only while that pid is alive, so a stale one never blocks.
   A live holder is sent SIGTERM first, and the file is removed at the end
   only if the line is still the watcher's own. `start` itself refuses
   (`watchInProgress`) while a live watcher holds it;
2. waits for the asking app to exit (`quittingPID`, up to `quitSeconds`),
   then opens the new build;
3. finds its process, running the destination's main executable, within
   `startSeconds`;
4. for a server, waits for an answer from `healthURL` (any HTTP status
   counts) within `firstAnswerSeconds`. With `listenerMustBeWatched`, the
   process listening on its port, where lsof shows it, must be the watched
   one, so an old process still answering doesn't count;
5. checks the process is still running `seconds` (120 by default) later.

If all of that passes, the backup is discarded and the note
(`WatchNote`, JSON at `notePath`) says `stayedUp`. If any step fails, the
new process is sent SIGTERM, the backup is restored (refused if the build
in place has changed since) and opened again, and the note says
`restored` with why, or `restoreFailed` with both whys. The app reads the
note at its next launch (`WatchNote.read`).

The service checks the watch first (`StayUpWatcher.checked`): it uses its
own policy, whatever the app sent, and writes the lock and the note only in
the policy's `zipFolders` or `watchFolders`.

## The service's interface

`UpdateKitInstallXPC` is the XPC interface, shared by every app that embeds
such a service. Its values are this module's Codable types as JSON, and its
replies are `InstallReply`s. The service exports
`UpdateKitInstallHandler(policy:)` (one call at a time, with its own
policy); the app calls it through `UpdateKitInstallClient(serviceName:)`:

    let installer = UpdateKitInstallClient(serviceName: "<the app's id>.Installer")
    switch await installer.install(BundleInstallRequest(zipPath: zip.path, bundleID: id, sha256: digest, name: name)) {
    case .success(let result):
        _ = await installer.watch(StayUpWatch(install: result, bundleID: id, quittingPID: getpid(),
                                              lockPath: lock, notePath: note))
        NSApplication.shared.terminate(nil)
    case .failure(let refusal):
        show(refusal)          // refusal.code, refusal.reason
    }

## Checking it in CI

A unit test can't show that the new copy opens, since quarantine,
translocation and the launch are the system's. An app that uses this
library checks it the way it updates: in a VM, with the app built and
signed as the job builds it, the real path end to end:

1. install the build being checked, then a second build of it (its version
   one higher) downloaded into the app's container;
2. ask the app to update itself through its service (the same call its
   update makes);
3. check the destination holds the second build, with no
   `com.apple.quarantine` on it, and that it opens: its process is
   running, and it answers whatever the app answers once started;
4. fail the job, with the service's refusal or the launch's error, if not.
