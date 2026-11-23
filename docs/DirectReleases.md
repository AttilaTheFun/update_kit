# Checking an app's own releases (UpdateKit 0.19)

The owner, 2026-11-23: "apps with update kit can directly check if an
update is available by checking their own github releases." Without it an
app learns of a newer build only from Applications, which writes `latest_*`
into the shared database after each of its syncs; an app on a device with
no Applications running (or none installed) never hears of one. With a
GitHub sign-in the app already holds, it can ask GitHub itself.

It learns only: nothing new is shown or installed. What reads `latest_*`
today (the app's own update handler, Applications' tab, Shireworks' own
self-update) sees the update sooner.

## What the app says

- **Info.plist, stamped by the distributor's CI** (a public repository
  names none of it, as `UpdateKitAppGroup` already):
  `UpdateKitReleasesRepository`, the `owner/name` of the repository whose
  releases carry the app's builds (their `builds.json`, as Applications
  reads them). `UpdateKitInfo.releasesRepository(in:)` takes exactly an
  owner and a name; a build variable no build filled in
  (`$(UPDATE_KIT_RELEASES_REPOSITORY)`), an empty string or anything else
  is none.
- **A token provider, before `start`:**

      AppUpdates.register(token: { try await signIn.accessToken() })

  asked before each check. UpdateKit depends on no sign-in library. With no
  provider registered, or no repository in the Info.plist, it checks
  nothing itself and works as before; a provider that returns an empty
  token (signed out) checks nothing that time; one that throws is logged.

## What UpdateKit does

`AppUpdates.start()`, with both, checks at start and then at most once an
hour while the app runs (`UpdateSession.checkReleases`, with a
`ReleaseChecker`):

1. `GET https://api.github.com/repos/{repository}/releases?per_page=10`
   with `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`,
   `X-GitHub-Api-Version: 2022-11-28`, and `If-None-Match` with the ETag of
   its last answer: a 304 costs nothing and the list kept in memory is
   read again.
2. The releases the installed variant (`BuildVariant`, Production when it
   says none) takes: **Production**, those published and not pre-releases;
   **Beta**, those published, pre-releases too; **Alpha** and **AdHoc**,
   any, drafts too (a proposal's). A variant not known is taken as
   Production.
3. Each such release's `builds.json` asset, fetched once per asset id
   (`GET …/releases/assets/{id}`, `Accept: application/octet-stream`; the
   redirect to where the file is kept followed without the token). Its
   lines for this bundle id, platform (`ios`, `macos`) and variant, signed
   (`signed` not false) and not an experiment's (no `purpose`), are the
   candidates; the highest (`AppVersion`: version, then build) is taken.
4. If it is newer than the running build, `AppGroupStore.offerLatest`
   writes it, in one transaction that takes the write lock: only where the
   row knows of no newest build, or of an older one, so it never lowers
   what Applications wrote. When it writes, `install_url` is written with
   it, empty: a direct check has no install link (on iOS the over-the-air
   manifest is Applications' to upload), and an older build's link must
   not stay beside a newer version. Applications' own `setLatest` writes
   what it synced, as before, its install link with it.
5. When it wrote, the group's signal is posted and the app's check runs
   again, as after an Applications sync: the app's own offers are looked
   at again, and Applications' tab hears of it.

Errors (no network, a token GitHub refused, a repository it doesn't show
the token's holder) are logged quietly and tried again at the next check.

`ReleaseChecker` is portable, its transport a closure
(`ReleaseChecker.Send`, a `ReleaseRequest` in, a `ReleaseAnswer` out); the
default is URLSession's.

## Not in 0.19

- Installing from a direct check: still Applications', or the app's own
  handler's (a Mac app with an installer service, UpdateKitInstall).
- Writing the over-the-air manifest on iOS (it needs a release asset
  uploaded; Applications does it, with its own rules).

## Tests

On Linux, with GitHub faked through the transport (ReleaseCheckerTests):
the requests' headers, the ETag sent again and a 304's list reused,
releases taken by variant (drafts and pre-releases), builds.json read once
an asset id, the highest of several lines, nothing when none is newer, and
other bundle ids, platforms, variants, unsigned and experiments' builds
passed over. AppGroupStoreTests: `offerLatest` only raises, and clears an
older build's install link. UpdateSessionTests: a direct check writes once
and never lowers Applications' build. UpdateKitInfoTests: the repository
read from an Info.plist.
