# Checking an app's own releases (design, UpdateKit 0.19)

The owner, 2026-11-23: "apps with update kit can directly check if an
update is available by checking their own github releases." Today an app
learns of a newer build only from Applications, which writes `latest_*`
into the shared database after each of its syncs; an app on a device with
no Applications running (or not installed) never hears of one. With a
GitHub sign-in the app already holds (a sign-in shared by the owner's apps,
GitHubAuth's in shake_kit), it can ask GitHub itself.

## What the app says

- **Info.plist, stamped by the distributor's CI** (a public repository
  names none of it, as `UpdateKitAppGroup` already):
  `UpdateKitReleasesRepository`, `owner/name` of the repository whose
  releases carry the app's builds (their `builds.json`, as Applications
  reads them).
- **A token, at launch, before `start`:**
  `AppUpdates.register(token: { try await credentials.access() })`. UpdateKit
  depends on no sign-in library; with no token registered (or none given:
  signed out, a build for other people), it checks nothing itself and works
  as today.

## What UpdateKit does

At `start` (and at most once an hour after, while the app runs, and on
`check()`):

1. `GET /repos/{repository}/releases?per_page=10`, with the ETag of its last
   answer (a 304 costs nothing), newest first; drafts are skipped, and
   pre-releases taken only for a beta build (the installed variant's, as
   Applications decides).
2. For the newest release with a `builds.json` asset, the asset (once per
   asset id), and in it the entry for this bundle id and platform (and, on
   a Mac, the variant).
3. If that build is newer than the installed one, `setLatest` on the shared
   database, as Applications would write it (`latest_version`,
   `latest_build`; `install_url` only where it can be made without writing,
   on a Mac the asset's API URL, on iOS none: the over-the-air manifest is
   Applications' to upload). Applications, when it next syncs, writes the
   same, so neither overrides the other with something older (`setLatest`
   keeps the newest).

So nothing new is shown or installed by UpdateKit: what reads `latest_*`
today (the app's own update handler, Applications' tab, Shireworks' own
self-update) sees the update sooner, and on a device with no Applications
at all, the app's own handler can offer it.

## Not in 0.19

- Installing from a direct check: still Applications', or the app's own
  handler's (a Mac app with an installer service, UpdateKitInstall).
- Writing the over-the-air manifest on iOS (it needs a release asset
  uploaded; Applications does it, with its own rules).

## Tests

On Linux, with GitHub's answers faked through the token closure's
transport: the releases read with their ETag, drafts and pre-releases by
variant, the builds.json entry chosen, the database written only for a
newer build, nothing done without a token or a repository.
