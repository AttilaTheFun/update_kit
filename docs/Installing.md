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
`InstallRefusal` (a stable `code` to phrase it by, and a plain `reason`;
an unknown code decodes as `.unknown`), with nothing after it done:

1. the bundle id is one of the policy's `apps`, exactly, by the one name
   it has there (so `<applications>/<name>.app` is that app's). A
   prefix is never enough: an unsandboxed helper of the same family is
   only installed if the policy names it;
2. the zip, its links resolved, is a file inside one of the policy's
   `zipFolders` (never reached through a link out of them: a container's
   Downloads is a link to the user's);
3. it is copied from one opening of it (`O_NOFOLLOW`; a plain file, no
   larger than `maxZipBytes`, its opened path still in those folders by
   `F_GETPATH`), its bytes alone, into a fresh folder of the service's
   own, and the copy's SHA-256 is the one given; what its directory says
   it unpacks to (`zipinfo -t`) is no more than `maxUnpackedBytes`. Only the copy is used
   from here on, so the app can't change the file between the check and
   the unpacking;
4. the copy, unpacked into its own subfolder by `ditto -x -k --noqtn`
   within the policy's `unpackTimeLimit` (five minutes; a stuck ditto is
   stopped), and stopped too once it has written more than
   `maxUnpackedBytes` (looked at each second: a zip whose directory says
   less than it holds), comes to no more than `maxUnpackedBytes` and holds exactly
   one app, which is a folder itself, never a link to one;
5. its signature passes the policy's `signing`. It's valid (strict, every
   architecture, nested code), and meets a requirement that always names
   Apple's anchor and the service's own team, so a self-signed
   certificate claiming the team fails. `developerID`, the default, also
   requires the team's Developer ID Application certificate and
   notarization, and refuses when notarization can't be checked (offline,
   by the build's stapled ticket: staple every release). `team`
   takes any certificate of the team's. `adHocForTests` (a test build of
   the service with no team) is honoured only by a debug build of this
   library;
6. what is at the destination is that app (or one of its
   `earlierIDSuffixes` ids), and the build is newer than it
   (`CFBundleVersion`) unless the policy `allowsDowngrade` (a person
   choosing an older version in a distributor). Or nothing is there,
   unless the policy is `updateOnly` (an app updating itself installs
   nothing new).

Then the app is checked again to be a folder, any quarantine left is
removed, it is swapped into place in one rename (`renamex_np`'s
`RENAME_SWAP`; `RENAME_EXCL` where nothing was there), and it is
registered with LaunchServices. A refusal before the swap leaves the
applications folder as it was.

The service's folder (`MacBundleInstallSystem.ownFolder`) is its own,
named by its bundle id, never shared with another app's service.

## The backup

The copy an install replaced stays in the service's folder, unregistered
from LaunchServices, beside a manifest (`BackupManifest`) of its bundle
id, name and destination, and the SHA-256 of the main executable of the
build that replaced it. `InstallResult.backup` is its opaque id:

- `BundleInstall.discard(backup:system:)` once the new build has stayed
  up: removed, unless a process still runs from it (an app that updated
  itself, until it has quit), when a later install sweeps it;
- `BundleInstall.restore(backup:policy:system:)` when it hasn't: the
  backup put back at the destination its manifest names, and nowhere
  else. It's refused unless the manifest's app is the policy's, the
  backup is still a whole app (a folder of that bundle id that passes
  the signature check), and the build in place is still the one the
  install put there (its executable's SHA-256), or nothing is there. So
  a later update, or the person's own change, is never undone;
- one neither discarded nor restored, that nothing runs from, is swept by
  an install after the policy's `backupLifetime` (a day by default).

## Staying up

Once the new build is in place, the app asks its service to watch it
(`StayUpWatch`) and, once the watch has started, quits. The service can't
do the watching itself, since launchd ends it with the app. So
`StayUpWatchLauncher.start` copies the service's own bundle into the
service's folder (a copied bundle stays validly signed, and the build in
place can change under it) and starts a one-shot launchd job of the
user's (`gui/<uid>`, `AbandonProcessGroup`) that runs the copy in watch
mode. The watcher (`StayUpWatcher`):

1. takes the policy's lock (`watchLockPath`, `WatchLock`): a file holding
   `<pid> <started-epoch-seconds>`, which counts only while that pid
   (above 1) is alive, so a stale one never blocks. A live holder is
   sent SIGTERM, and then a second is waited, only if its executable is
   in the service's own folder (a watcher), so a line anyone else wrote
   never has a process signalled. The file is removed at the end only if
   the line is still the watcher's own. `start` takes it at once, in the
   service's name, until the watcher takes it over; `start` and every
   install refuse (`watchInProgress`) while it's held;
2. waits for the asking app to exit (`quittingPID`, up to
   `quitSeconds`). An app that doesn't quit has its update undone, not
   opened over. Then it opens the new build;
3. finds its process, running the destination's main executable, within
   `startSeconds`;
4. for a server, waits for an answer from `healthURL`, which must be on
   this Mac (loopback); any HTTP status counts, within
   `firstAnswerSeconds`. With `listenerMustBeWatched`, the processes
   listening on its port, where lsof shows them, must include the
   watched one, so an old process still answering doesn't count;
5. checks the process is still running `seconds` (120 by default) later.

If all of that passes, the backup is discarded and the note (`WatchNote`,
JSON at the policy's `watchNotePath`) says `stayedUp`. If any step fails,
the new process is sent SIGTERM (then SIGKILL, five seconds later, if
it's still there), the backup is restored and opened again, and the note
says `restored` with why, or `restoreFailed` with both whys. The lock and
the note are written through their folder opened without following a
link, and never through a link themselves; the note is written whole,
into a new file renamed over it. They're the policy's, never the app's
to choose, so put each directly in a folder the sandboxed app can't write
or replace, nor any folder above it (never in its container or an app
group's). The app reads the note through its service (`note(remove:)`),
since it can't read that folder itself. If launchd ends the service as the
app quits, before the watcher has taken the lock over, the lock is the
service's own until its pid is gone, which only blocks installs for that
moment.

The service checks the watch first (`StayUpWatcher.checked`): its app is
the policy's at its destination, its backup is one the service keeps,
and its health URL is on this Mac. The watcher, started with a watch file
and a label, takes only a file in a folder of the service's own with the
label its start gave, and checks the watch again.

## The service

`UpdateKitInstallService.main(policy:)` is the whole of a service's
`main`. Run as a watcher, it carries out the watch and exits. Otherwise
it is the XPC listener, which takes connections only from code meeting a
requirement: by default the app the service is in, by its bundle id,
Apple's anchor and the service's own team, checked by the system on every
message by the caller's audit token. Each call is served, one at a time,
by `UpdateKitInstallHandler` with the service's policy.

`UpdateKitInstallXPC` is the interface, shared by every app that embeds
such a service. Its values are this module's Codable types as JSON, and
its replies are `InstallReply`s. The app calls it through
`UpdateKitInstallClient(serviceName:)`, whose calls give up after 15
minutes (`unreachable`):

    let installer = UpdateKitInstallClient(serviceName: "<the app's id>.Installer")
    switch await installer.install(BundleInstallRequest(zipPath: zip.path, bundleID: id, sha256: digest, name: name)) {
    case .success(let result):
        switch await installer.watch(StayUpWatch(install: result, bundleID: id, quittingPID: getpid())) {
        case .success:
            NSApplication.shared.terminate(nil)  // the watcher opens the new build
        case .failure(let refusal):
            // Not watched: put the earlier build back rather than quit with nothing to reopen it.
            if let backup = result.backup { _ = await installer.restore(backup: backup) }
            show(refusal)
        }
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
