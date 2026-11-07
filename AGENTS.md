# Update Kit, for agents

ApplicationUpdates, the library every app Applications distributes links
to record the build it is and hear of its own updates. docs/Updates.md is
its design. Moved here from AttilaTheFun/applications (its
libraries/application_updates) on 2026-11-07, at v0.10.45, so the apps
fetch it from a public repository.

- **This repository is public.** Never add a person's name (write "the
  owner"), a device or host name, a real IP address or hostname, a private
  project's name, or any secret, key, token, team ID or UDID.
- **Nothing goes to main but through a pull request.** Agents merge their
  own once CI (linux, ios-tests) is green and the branch is up to date,
  except those touching .github/, which need the owner's review.
- **Versions are tags,** `vMAJOR.MINOR.PATCH`, which the apps pin
  `exact:`. A tag is the owner's (or made on the owner's word).
- **Portable:** `swift test` passes on Linux and on a Mac; Apple's
  frameworks stay behind `canImport`.
