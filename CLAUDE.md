# CLAUDE.md: Prompt Paws

Notes for Claude Code (and people) working on this repo. Read `README.md` first: controls, hooks,
character format, build and checks.

## Rules
- After any change: `./build.sh`, then `"build/Prompt Paws.app/Contents/MacOS/PromptPaws" --selftest` must
  end in `SELFTEST PASS`. After a change to rendering or the character, also run `python3 tools/measure.py`
  and compare with the README numbers.
- Before anything goes public (a push, a release): `tools/check-public.sh` must print `check-public: OK`.
- Keep the panda calm: Claude's state goes in the bubble, not in running around. Stay and Sleep are strict
  (no walking; sleep until clicked).
- Meshy moves are never copy-ready: each rigging run has its own skeleton and its own floor height. Add moves
  only through `tools/build-panda.sh` (retarget + ground), then check them against Meshy's own file side by
  side and check the floor contact.
- For visual checks use `node tools/review.mjs <character>` (headless Chrome renders). Screenshots of the
  real screen need Screen Recording permission.
- The self-test puts the pet on the real screen and adds (then removes) fake session files
  `~/.promptpaws/sessions/promptpaws-selftest*`; the test instance reads only those.
- Every Claude Code session on the Mac with the plugin installed feeds the pet, so the bubble changes while
  you test.
- Swift from the Command Line Tools, no Xcode: top-level code only in `main.swift`. Minimum macOS 13.
- The page must load through `pet://` (`SchemeHandler`); file:// URLs block ES modules and fetch.
- Option+Command+P also toggles Finder's path bar while the app runs.
- New characters or moves cost credits on paid services: ask the owner first, with model, runs and cost.
- Release: bump `CFBundleShortVersionString` in `Info.plist` and `version` in
  `plugin/.claude-plugin/plugin.json` together, `./build.sh --zip`, tag `v<version>`, `gh release create`.
