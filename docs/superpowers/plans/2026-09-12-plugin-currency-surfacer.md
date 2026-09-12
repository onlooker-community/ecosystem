# Plugin Currency Surfacer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Warn at SessionStart, unasked, when the plugin code a session is about to run is not the code on main.

**Architecture:** A substrate SessionStart hook shells out to the existing
`check-plugin-installs.mjs` rather than reimplementing it, caches the answer with
a TTL so the network probe is rare, and injects a one-line pointer. The governing
rule is that an expired cache reports "unchecked", never "current".

**Tech Stack:** bash hooks, `jq`, Node for the check and the event emitter, bats
for hook tests, `node:test` for the flag tests, JSON Schema in a sibling repo.

**Spec:** `docs/superpowers/specs/2026-09-12-plugin-currency-surfacer-design.md`

## Global Constraints

- Two repos. `~/src/github.com/onlooker-community/schema` first, then this one.
- Branch the schema work from a freshly updated `main`. The local checkout sits on
  `feat/watch-unmatched`, one **unpushed** commit on top of 2.17.0, two releases
  behind. Do not build on that branch and do not touch that commit.
- `npx` is blocked in this environment. Use `./node_modules/.bin/<tool>` directly.
  This affects the schema repo's `npm run lint` / `npm run ci`, which call `npx`.
- Every hook exits 0, always. Hooks never block a session. Assert on emitted
  events and on-disk artifacts, never on a non-zero exit code.
- Emit only through `scripts/lib/onlooker-event.mjs`. Never append to the log.
- Use `$ONLOOKER_DIR`, never a literal `~/.onlooker`.
- Every bats file sources `test/helpers/setup.bash` and calls `setup_test_env`.
- Non-final `[[ ]]` and non-final `!` assertions in bats need `|| return 1`.
  Under bash 3.2 a failing non-final `[[ ]]` does not fail the test body.
- American English in all commits, comments, and docs.
- Commits go through the `/commit` skill. Never push to `main`; open a PR.
- ULIDs, not UUIDs.

---

## Task 1: Register the three event types (schema repo)

**Repo:** `~/src/github.com/onlooker-community/schema`

**Files:**

- Modify: `schemas/event.v1.json` (the `event_type` enum)
- Modify: `schemas/payload/plugins-ops.json`
- Modify: `src/event-types.ts`
- Modify: `src/index.ts`
- Modify: `src/types.ts`
- Test: `src/validate.test.ts`

**Interfaces:**

- Produces: event types `onlooker.currency.checked`, `onlooker.currency.stale`,
  `onlooker.currency.skipped`; TS constants `ONLOOKER_CURRENCY_CHECKED`,
  `ONLOOKER_CURRENCY_STALE`, `ONLOOKER_CURRENCY_SKIPPED`; interfaces
  `OnlookerCurrencyCheckedPayload`, `OnlookerCurrencyStalePayload`,
  `OnlookerCurrencySkippedPayload`.

This is the template used by `1e5a33d` (inspector's ten types) — the same seven
files, in the same order.

- [ ] **Step 1: Branch from an updated main**

```bash
cd ~/src/github.com/onlooker-community/schema
git fetch origin
git switch --detach origin/main
git switch -c feat/onlooker-currency-events
git log --oneline -1   # expect 5751691, release 2.19.0 (#63)
```

- [ ] **Step 2: Write the failing tests**

Append to `src/validate.test.ts`:

```typescript
describe("onlooker.currency.*", () => {
	it("accepts a checked event", () => {
		expect(
			isValidEvent({
				schema_version: "1.0.0",
				event_id: "01JQ0000000000000000000000",
				event_type: "onlooker.currency.checked",
				emitted_at: "2026-09-12T04:11:07Z",
				source: "claude-code",
				plugin: "onlooker",
				session_id: "s1",
				payload: {
					probe_outcome: "ok",
					marketplaces_checked: 1,
					findings_count: 1,
					duration_ms: 412,
				},
			}),
		).toBe(true);
	});

	it("accepts a stale event carrying its answer age", () => {
		expect(
			isValidEvent({
				schema_version: "1.0.0",
				event_id: "01JQ0000000000000000000001",
				event_type: "onlooker.currency.stale",
				emitted_at: "2026-09-12T04:11:07Z",
				source: "claude-code",
				plugin: "onlooker",
				session_id: "s1",
				payload: {
					findings_count: 1,
					answer_age_seconds: 7200,
					findings: [
						{
							reason: "clone_behind",
							subject: "onlooker-community",
							effective: "6caacd39",
							available: "ff773b41",
						},
					],
				},
			}),
		).toBe(true);
	});

	it("rejects a skipped event with an unknown skip_reason", () => {
		expect(
			isValidEvent({
				schema_version: "1.0.0",
				event_id: "01JQ0000000000000000000002",
				event_type: "onlooker.currency.skipped",
				emitted_at: "2026-09-12T04:11:07Z",
				source: "claude-code",
				plugin: "onlooker",
				session_id: "s1",
				payload: { skip_reason: "because_i_said_so" },
			}),
		).toBe(false);
	});
});
```

Then change the existing count assertion at `src/validate.test.ts:2207` from
`126` to `129`:

```typescript
	it("has exactly 129 entries", () => {
		expect(ALL_EVENT_TYPES.length).toBe(129);
	});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `npm test`
Expected: FAIL. The three new cases fail because the types are not in the enum,
and the count assertion fails with `expected 126 to be 129`.

- [ ] **Step 4: Add the three types to the enum**

In `schemas/event.v1.json`, append to the `event_type` enum array, after the last
existing entry:

```json
				"onlooker.currency.checked",
				"onlooker.currency.stale",
				"onlooker.currency.skipped"
```

- [ ] **Step 5: Add the payload definitions**

In `schemas/payload/plugins-ops.json`, add to `$defs`:

```json
		"OnlookerCurrencyCheckedPayload": {
			"type": "object",
			"required": ["probe_outcome"],
			"additionalProperties": false,
			"properties": {
				"probe_outcome": {
					"type": "string",
					"enum": ["ok", "failed"],
					"description": "failed means the probe could not reach a marketplace origin. The cached answer is left untouched rather than restamped, so a failed probe never makes a stale answer look fresh."
				},
				"marketplaces_checked": { "type": "integer", "minimum": 0 },
				"findings_count": { "type": "integer", "minimum": 0 },
				"duration_ms": { "type": "integer", "minimum": 0 }
			}
		},
		"OnlookerCurrencyStalePayload": {
			"type": "object",
			"required": ["findings_count", "answer_age_seconds"],
			"additionalProperties": false,
			"properties": {
				"findings_count": { "type": "integer", "minimum": 1 },
				"answer_age_seconds": {
					"type": "integer",
					"minimum": 0,
					"description": "Age of the cached answer this event reports. Always present, because a currency claim without its age is the failure this event type exists to avoid."
				},
				"findings": {
					"type": "array",
					"items": {
						"type": "object",
						"required": ["reason", "subject"],
						"additionalProperties": false,
						"properties": {
							"reason": {
								"type": "string",
								"enum": [
									"clone_behind",
									"stale_install",
									"not_installed",
									"installed_elsewhere"
								]
							},
							"subject": {
								"type": "string",
								"description": "The marketplace name for clone_behind, otherwise the plugin key."
							},
							"effective": { "type": "string" },
							"available": { "type": "string" }
						}
					}
				}
			}
		},
		"OnlookerCurrencySkippedPayload": {
			"type": "object",
			"required": ["skip_reason"],
			"additionalProperties": false,
			"properties": {
				"skip_reason": {
					"type": "string",
					"enum": [
						"cache_fresh",
						"disabled",
						"no_manifest",
						"no_git_context",
						"budget_exceeded",
						"probe_failed"
					],
					"description": "Named rather than collapsed to a single skip, because 'nothing to report' and 'could not check' are opposite conditions that are otherwise indistinguishable in the log. See ecosystem-449.39 for the same mistake made against librarian.scan.complete."
				},
				"answer_age_seconds": { "type": "integer", "minimum": 0 }
			}
		},
```

Wire each into the payload dispatch the same way the neighboring `inspector.*`
entries in this file do — match the surrounding `if`/`then` conditional style
exactly rather than inventing a new one.

- [ ] **Step 6: Add the TypeScript constants**

In `src/event-types.ts`, after the last existing `export const` block:

```typescript
export const ONLOOKER_CURRENCY_CHECKED = "onlooker.currency.checked" as const;
export const ONLOOKER_CURRENCY_STALE = "onlooker.currency.stale" as const;
export const ONLOOKER_CURRENCY_SKIPPED = "onlooker.currency.skipped" as const;
```

Add all three to the `ALL_EVENT_TYPES` array (starting line 181), preserving the
grouping style of the surrounding entries.

- [ ] **Step 7: Add the hand-written interfaces**

`src/types.ts` is hand-written and cross-checked by `generate-types.js` rather
than produced by it, so it must be updated by hand:

```typescript
export interface OnlookerCurrencyCheckedPayload {
	/**
	 * `failed` means the probe could not reach a marketplace origin. The cached
	 * answer is left untouched rather than restamped, so a failed probe never
	 * makes a stale answer look fresh.
	 */
	probe_outcome: "ok" | "failed";
	marketplaces_checked?: number;
	findings_count?: number;
	duration_ms?: number;
}

export interface OnlookerCurrencyFinding {
	reason: "clone_behind" | "stale_install" | "not_installed" | "installed_elsewhere";
	/** The marketplace name for `clone_behind`, otherwise the plugin key. */
	subject: string;
	effective?: string;
	available?: string;
}

export interface OnlookerCurrencyStalePayload {
	findings_count: number;
	/**
	 * Age of the cached answer this event reports. Always present, because a
	 * currency claim without its age is the failure this event type exists to
	 * avoid.
	 */
	answer_age_seconds: number;
	findings?: OnlookerCurrencyFinding[];
}

export interface OnlookerCurrencySkippedPayload {
	/**
	 * Named rather than collapsed to a single skip: "nothing to report" and
	 * "could not check" are opposite conditions that are otherwise
	 * indistinguishable in the log.
	 */
	skip_reason:
		| "cache_fresh"
		| "disabled"
		| "no_manifest"
		| "no_git_context"
		| "budget_exceeded"
		| "probe_failed";
	answer_age_seconds?: number;
}
```

Export the three constants and the four interfaces from `src/index.ts`, following
the existing export blocks there.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `npm test`
Expected: PASS, including `has exactly 129 entries`.

- [ ] **Step 9: Validate schemas and typecheck**

```bash
npm run validate-schemas
npm run typecheck
./node_modules/.bin/biome check .
```

Expected: all clean. Use the direct binary path — `npm run ci` shells out to
`npx`, which is blocked here.

- [ ] **Step 10: Commit and open the PR**

Use the `/commit` skill, then `/git-workflow:pr`. The commit body should say why
three types rather than one: `checked` records that a probe happened at all,
`stale` carries findings with their answer age, and `skipped` names why no probe
ran. Collapsing them loses the distinction between "clean" and "never looked".

- [ ] **Step 11: After the PR merges, confirm the release published**

```bash
npm view @onlooker-community/schema version
```

Expected: a version above 2.19.0. Do not start Task 5 until this is true.

---

## Task 2: Add the `--marketplace` scope filter

**Repo:** this one. **No dependency on Task 1** — it can be done in parallel.

**Files:**

- Modify: `scripts/lint/check-plugin-installs.mjs` (`parseArgs` ~line 60-88; the
  findings block ~line 420-455)
- Test: `test/node/check-plugin-installs.test.mjs`

**Interfaces:**

- Produces: `--marketplace <name>`, repeatable. Findings whose marketplace does
  not match are dropped before `report.status` is computed, so the exit code and
  the printed errors stay consistent with each other.

- [ ] **Step 1: Write the failing tests**

Add to `test/node/check-plugin-installs.test.mjs`. Use the helpers already in
that file — `scaffold()`, `writeSettings()`, `writeManifest()` and
`run(s, ...args)`, which returns `{ code, stdout, stderr }`. `MARKET` is the
module constant `'@onlooker-community'`; the second marketplace is spelled out
because there is no constant for it.

```javascript
const OTHER = '@meaganewaller-marketplace';

// Two enabled plugins from two marketplaces, neither installed, so each
// produces exactly one not_installed finding. The filter's job is to decide
// which of the two survives.
function twoMarketplacesBothMissing() {
  const s = scaffold();
  writeSettings(s.project, { [`lineage${MARKET}`]: true, [`mise${OTHER}`]: true });
  writeManifest(s.configDir, {});
  return s;
}

it('--marketplace reports only the named marketplace', () => {
  const s = twoMarketplacesBothMissing();
  const r = run(s, '--marketplace', 'onlooker-community');
  assert.equal(r.code, 1);
  assert.match(r.stderr, /lineage@onlooker-community/);
  assert.doesNotMatch(r.stderr, /mise@meaganewaller-marketplace/);
});

it('--marketplace excludes other marketplaces from the exit code', () => {
  const s = scaffold();
  writeSettings(s.project, { [`mise${OTHER}`]: true });
  writeManifest(s.configDir, {});
  const r = run(s, '--marketplace', 'onlooker-community');
  assert.equal(r.code, 0, r.stderr);
});

it('repeating --marketplace unions the set', () => {
  const s = twoMarketplacesBothMissing();
  const r = run(s, '--marketplace', 'onlooker-community', '--marketplace', 'meaganewaller-marketplace');
  assert.equal(r.code, 1);
  assert.match(r.stderr, /lineage@onlooker-community/);
  assert.match(r.stderr, /mise@meaganewaller-marketplace/);
});

it('an unknown --marketplace yields no findings rather than an error', () => {
  const s = twoMarketplacesBothMissing();
  const r = run(s, '--marketplace', 'does-not-exist');
  assert.equal(r.code, 0, r.stderr);
});

it('omitting --marketplace preserves existing behavior exactly', () => {
  const s = twoMarketplacesBothMissing();
  const r = run(s);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /lineage@onlooker-community/);
  assert.match(r.stderr, /mise@meaganewaller-marketplace/);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test test/node/check-plugin-installs.test.mjs`
Expected: FAIL with `unknown argument --marketplace` (the parser exits 2 today).

- [ ] **Step 3: Parse the flag**

In `parseArgs`, add `marketplaces: []` to the `args` object literal, then add the
branch before the `--help` branch:

```javascript
    else if (a === '--marketplace') args.marketplaces.push(argv[++i]);
```

Update the usage string in the `--help` branch to include
`[--marketplace <name>]`.

- [ ] **Step 4: Filter the findings**

Immediately before the `report.status = ...` assignment, add:

```javascript
  // Scope filter. A finding names either a marketplace directly (clone_behind)
  // or a plugin keyed `name@marketplace`. Filtering here rather than at print
  // time keeps the exit code and the printed errors agreeing with each other.
  if (args.marketplaces.length > 0) {
    const wanted = new Set(args.marketplaces);
    report.findings = report.findings.filter((f) => {
      const name = f.marketplace ?? String(f.plugin ?? '').split('@')[1];
      return wanted.has(name);
    });
  }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `node --test test/node/check-plugin-installs.test.mjs`
Expected: PASS, all five new tests plus the 18 existing ones.

- [ ] **Step 6: Confirm it behaves on real local state**

```bash
CLAUDE_HOME=~/.claude-personal node scripts/lint/check-plugin-installs.mjs \
  --marketplace onlooker-community --report
echo "exit=$?"
```

Expected: the mise / dotfiles / git-workflow / superpowers-dev /
conorbronsdon-skills findings are gone; the `onlooker-community` clone-behind
finding remains. Capture the exit code with `echo "exit=$?"` on its own line —
piping to `tail` reports the exit code of `tail`, not of the check.

- [ ] **Step 7: Commit**

Use the `/commit` skill. Scope `lint`.

---

## Task 3: Config accessors and shipped defaults

**Files:**

- Modify: `config.json` (root — the substrate's shipped defaults)
- Create: `scripts/lib/plugin-currency-config.sh`
- Test: `test/bats/plugin-currency-config.bats`

**Interfaces:**

- Consumes: `config_load_plugin`, `config_get`, `config_get_json` from
  `scripts/lib/config-loader.sh`.
- Produces: `plugin_currency_config_load <repo_root>`,
  `plugin_currency_config_get <jq-path>`, `plugin_currency_config_get_json <jq-path>`.

- [ ] **Step 1: Write the failing test**

`test/bats/plugin-currency-config.bats`:

```bash
setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
}

@test "ships the documented defaults" {
  source "${REPO_ROOT}/scripts/lib/plugin-currency-config.sh"
  plugin_currency_config_load "$PROJECT_REPO"
  [ "$(plugin_currency_config_get '.plugin_currency.enabled')" = "true" ]
  [ "$(plugin_currency_config_get '.plugin_currency.probe_ttl_hours')" = "6" ]
  [ "$(plugin_currency_config_get '.plugin_currency.surface_when_current')" = "false" ]
  [ "$(plugin_currency_config_get_json '.plugin_currency.marketplaces')" = '["onlooker-community"]' ]
}

@test "a project setting overrides the shipped default" {
  mkdir -p "${PROJECT_REPO}/.claude"
  jq -n '{plugin_currency: {probe_ttl_hours: 1}}' \
    > "${PROJECT_REPO}/.claude/settings.json"
  source "${REPO_ROOT}/scripts/lib/plugin-currency-config.sh"
  plugin_currency_config_load "$PROJECT_REPO"
  [ "$(plugin_currency_config_get '.plugin_currency.probe_ttl_hours')" = "1" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats test/bats/plugin-currency-config.bats`
Expected: FAIL — the lib does not exist.

- [ ] **Step 3: Add the shipped defaults**

In the root `config.json`, add beside `prompt_rules`:

```json
  "plugin_currency": {
    "enabled": true,
    "marketplaces": ["onlooker-community"],
    "probe_ttl_hours": 6,
    "wall_clock_budget_ms": 1500,
    "surface_when_current": false,
    "max_pointer_chars": 200
  }
```

- [ ] **Step 4: Write the accessor lib**

`scripts/lib/plugin-currency-config.sh`, mirroring
`plugins/curator/scripts/lib/curator-config.sh`. Resolve the loader from this
file's own `${BASH_SOURCE[0]}` — never from a caller-supplied `$PLUGIN_ROOT`, and
never via a path that climbs to the repo root:

```bash
#!/usr/bin/env bash
# Config resolution for the plugin-currency surfacer.

_PC_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PC_CONFIG_LOADER="${_PC_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_PC_CONFIG_LOADER" ]]; then
	printf 'plugin-currency: missing %s — package is incomplete\n' \
		"$_PC_CONFIG_LOADER" >&2
	exit 1
fi
# shellcheck source=scripts/lib/config-loader.sh
source "$_PC_CONFIG_LOADER"

_PLUGIN_CURRENCY_CONFIG="{}"

plugin_currency_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "plugin_currency" "$repo_root" "_PLUGIN_CURRENCY_CONFIG"
	return 0
}

plugin_currency_config_get() {
	local path="$1"
	config_get "_PLUGIN_CURRENCY_CONFIG" "${path}"
}

plugin_currency_config_get_json() {
	local path="$1"
	config_get_json "_PLUGIN_CURRENCY_CONFIG" "${path}"
}
```

Two details this sketch originally got wrong, both corrected above after
reading `scripts/lib/config-loader.sh` rather than assuming its shape:

- `config_get` takes the **variable name**, not the variable's value. Passing
  the value returns empty for every key, silently — no error, just defaults.
- jq paths carry the namespace key: `.plugin_currency.probe_ttl_hours`, the same
  way `curator_config_get '.curator.cheap_checks.enabled'` does.

- [ ] **Step 5: Run to verify it passes**

Run: `bats test/bats/plugin-currency-config.bats`
Expected: PASS, both tests.

- [ ] **Step 6: Commit**

Use the `/commit` skill.

---

## Task 4: The probe cache and the age rule

This is the load-bearing task. The age rule is the one invariant whose breakage
recreates the outage the feature exists to catch.

**Files:**

- Create: `scripts/lib/plugin-currency-cache.sh`
- Test: `test/bats/plugin-currency-cache.bats`

**Interfaces:**

- Produces:
  - `plugin_currency_cache_path <project_key>` — echoes the probe.json path.
  - `plugin_currency_cache_age_seconds <path>` — echoes the age of `checked_at`
    in seconds, or empty if the file is absent or unparseable.
  - `plugin_currency_cache_is_fresh <path> <ttl_hours>` — returns 0 when fresh,
    1 otherwise. Returns 1 for a missing or unparseable file.
  - `plugin_currency_cache_write <path> <findings_json>` — writes
    `{checked_at, findings}` with `checked_at` stamped now.

- [ ] **Step 1: Write the failing tests**

`test/bats/plugin-currency-cache.bats`. Note `relative_iso_days_ago` for every
age-sensitive fixture — a literal date here is a time bomb:

```bash
setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  source "${REPO_ROOT}/scripts/lib/plugin-currency-cache.sh"
  CACHE="${BATS_TEST_TMPDIR}/probe.json"
}

@test "a missing cache is not fresh" {
  ! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
  [ -z "$(plugin_currency_cache_age_seconds "$CACHE")" ]
}

@test "a just-written cache is fresh" {
  plugin_currency_cache_write "$CACHE" '[]'
  plugin_currency_cache_is_fresh "$CACHE" 6
}

@test "a cache older than the ttl is not fresh" {
  jq -n --arg t "$(relative_iso_days_ago 1)" \
    '{checked_at: $t, findings: []}' > "$CACHE"
  ! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
}

@test "an unparseable cache is not fresh" {
  printf 'not json' > "$CACHE"
  ! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
}

@test "a cache with no checked_at is not fresh" {
  jq -n '{findings: []}' > "$CACHE"
  ! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
}

@test "age is reported in seconds and grows with the fixture's age" {
  jq -n --arg t "$(relative_iso_days_ago 1)" \
    '{checked_at: $t, findings: []}' > "$CACHE"
  age=$(plugin_currency_cache_age_seconds "$CACHE")
  [ "$age" -gt 80000 ]
}

@test "write stamps checked_at and preserves the findings verbatim" {
  plugin_currency_cache_write "$CACHE" \
    '[{"reason":"clone_behind","subject":"onlooker-community"}]'
  jq -e '.checked_at | test("^[0-9]{4}-")' "$CACHE" >/dev/null || return 1
  jq -e '.findings[0].reason == "clone_behind"' "$CACHE" >/dev/null
}
```

The `is_fresh` tests are the mutation targets. Delete the age comparison from the
implementation and "a cache older than the ttl is not fresh" must fail. If it
still passes, the test is not testing what it claims.

- [ ] **Step 2: Run to verify they fail**

Run: `bats test/bats/plugin-currency-cache.bats`
Expected: FAIL — the lib does not exist.

- [ ] **Step 3: Implement the cache lib**

```bash
#!/usr/bin/env bash
# Probe cache for the plugin-currency surfacer.
#
# GOVERNING INVARIANT: absence of a finding in an EXPIRED cache is not evidence
# of currency. Every consumer must treat "not fresh" as "unknown", never as
# "current". Two instruments have already produced wrong conclusions this way in
# this epic: refs/remotes/origin/<branch> reported a behind clone as current, and
# lastUpdated read without installedAt made never-updated pins look fresh.

plugin_currency_cache_path() {
	printf '%s/currency/%s/probe.json' "$ONLOOKER_DIR" "${1:-unknown}"
}

plugin_currency_cache_age_seconds() {
	local path="${1:-}" stamp now then_ts
	[[ -f "$path" ]] || return 0
	stamp=$(jq -r '.checked_at // empty' "$path" 2>/dev/null) || return 0
	[[ -n "$stamp" ]] || return 0
	# python3 for portable date parsing: date -d is GNU, date -j -f is BSD.
	then_ts=$(python3 -c 'import sys,datetime;print(int(datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$stamp" 2>/dev/null) || return 0
	now=$(date -u +%s)
	printf '%s' "$(( now - then_ts ))"
}

plugin_currency_cache_is_fresh() {
	local path="${1:-}" ttl_hours="${2:-6}" age
	age=$(plugin_currency_cache_age_seconds "$path")
	[[ -n "$age" ]] || return 1
	[[ "$age" -lt $(( ttl_hours * 3600 )) ]]
}

plugin_currency_cache_write() {
	local path="${1:-}" findings="${2:-[]}"
	mkdir -p "$(dirname "$path")" || return 1
	jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson f "$findings" \
		'{checked_at: $t, findings: $f}' > "$path"
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `bats test/bats/plugin-currency-cache.bats`
Expected: PASS, all seven.

- [ ] **Step 5: Break it on purpose, confirm the test catches it**

Temporarily change `is_fresh` to `return 0` unconditionally. Re-run. Expect "a
cache older than the ttl is not fresh", "a missing cache is not fresh", "an
unparseable cache is not fresh", and "a cache with no checked_at is not fresh" to
all fail. Revert.

A test that passes whether or not the code is correct reports coverage that does
not exist, and this is the invariant least able to afford that.

- [ ] **Step 6: Commit**

Use the `/commit` skill.

---

## Task 5: The hook, wired and emitting

**Depends on Task 1 being published, and on Tasks 2-4.**

**Files:**

- Create: `scripts/hooks/plugin-currency-surfacer.sh`
- Modify: `hooks/hooks.json` (the `SessionStart` array)
- Modify: `package.json` (bump the `@onlooker-community/schema` devDependency)
- Modify: `test/bus-coverage.json`
- Test: `test/bats/plugin-currency-surfacer.bats`

**Interfaces:**

- Consumes: `plugin_currency_config_*` (Task 3), `plugin_currency_cache_*`
  (Task 4), `--marketplace` (Task 2), the three event types (Task 1).

- [ ] **Step 1: Bump the schema dependency**

```bash
npm install --save-dev @onlooker-community/schema@latest
git diff --stat package.json package-lock.json
```

Expected: both files move to the version published by Task 1.

- [ ] **Step 2: Write the failing tests**

`test/bats/plugin-currency-surfacer.bats`. Stub `node` is wrong here — stub the
**check script** by pointing the hook at a fixture, and stub nothing else. Drive
the hook with `jq`-built input and assert on the event log:

```bash
setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  HOOK="${REPO_ROOT}/scripts/hooks/plugin-currency-surfacer.sh"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git
}

_hook_input() {
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-test" \
    '{cwd: $cwd, session_id: $sid, hook_event_name: "SessionStart", source: "startup"}'
}

@test "always exits 0" {
  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "emits skipped with reason disabled when turned off" {
  mkdir -p "${PROJECT_REPO}/.claude"
  jq -n '{plugin_currency: {enabled: false}}' \
    > "${PROJECT_REPO}/.claude/settings.json"
  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  grep '"event_type":"onlooker.currency.skipped"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.skip_reason == "disabled"' >/dev/null
}

@test "a fresh cache is read without re-probing" {
  _seed_cache_now '[]'
  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  grep '"event_type":"onlooker.currency.skipped"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.skip_reason == "cache_fresh"' >/dev/null || return 1
  ! grep -q '"event_type":"onlooker.currency.checked"' "$ONLOOKER_EVENTS_LOG" || return 1
  [ -n "$(cat "$ONLOOKER_EVENTS_LOG")" ]
}

@test "an expired cache with findings never reports current" {
  _seed_cache_aged 1 '[{"reason":"clone_behind","subject":"onlooker-community"}]'
  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  ! printf '%s' "$output" | grep -qi 'current' || return 1
  printf '%s' "$output" | grep -qi 'unchecked'
}

@test "a stale finding surfaces with its answer age" {
  _seed_cache_now '[{"reason":"clone_behind","subject":"onlooker-community"}]'
  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  grep '"event_type":"onlooker.currency.stale"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.answer_age_seconds >= 0 and .payload.findings_count == 1' >/dev/null
}

@test "surfaces nothing when there is nothing to report" {
  _seed_cache_now '[]'
  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  [ -z "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')" ]
}
```

Add the two seeders to the file, resolving the project key through the substrate
rather than recomputing the SHA:

```bash
_cache_file() {
  source "${REPO_ROOT}/scripts/lib/plugin-currency-cache.sh"
  plugin_currency_cache_path "$(_project_key)"
}

_seed_cache_now() {
  local f; f=$(_cache_file); mkdir -p "$(dirname "$f")"
  jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson x "$1" \
    '{checked_at: $t, findings: $x}' > "$f"
}

_seed_cache_aged() {
  local f; f=$(_cache_file); mkdir -p "$(dirname "$f")"
  jq -n --arg t "$(relative_iso_days_ago "$1")" --argjson x "$2" \
    '{checked_at: $t, findings: $x}' > "$f"
}
```

Implement `_project_key` with the same helper the hook uses, so the test and the
hook cannot disagree about where the cache lives. If the substrate has no
project-key helper, add one in this task following
`plugins/tribunal/scripts/lib/tribunal-project-key.sh` and give it its own test.

- [ ] **Step 3: Run to verify they fail**

Run: `bats test/bats/plugin-currency-surfacer.bats`
Expected: FAIL — the hook does not exist.

- [ ] **Step 4: Write the hook**

`scripts/hooks/plugin-currency-surfacer.sh`. Register with hook-health *before*
any real work, and set context once stdin is read — skip either and the hook is
invisible to latency measurement, silently, with no test failure to flag it:

```bash
#!/usr/bin/env bash
# Surfaces stale plugin pins at SessionStart. See
# docs/superpowers/specs/2026-09-12-plugin-currency-surfacer-design.md
#
# Never blocks a session: exits 0 on every path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/hook-health.sh"
hook_health_register "plugin-currency-surfacer"

source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/plugin-currency-config.sh"
source "$SCRIPT_DIR/../lib/plugin-currency-cache.sh"

INPUT=$(cat)
hook_health_context "$INPUT"
```

Then: resolve `cwd` and `session_id` from `$INPUT` with `jq`; load config; emit
`skipped`/`disabled` and exit 0 if disabled; resolve the project key and emit
`skipped`/`no_git_context` if absent; compute the cache path.

If the cache is fresh, emit `skipped`/`cache_fresh` carrying
`answer_age_seconds`, surface from cache, exit 0. Otherwise run the probe under
`wall_clock_budget_ms`:

```bash
findings=$(timeout "${budget_s}" node \
	"${SCRIPT_DIR}/../lint/check-plugin-installs.mjs" --json \
	"${marketplace_args[@]}" 2>/dev/null | jq -c '.findings // []') || findings=""
```

On probe failure or timeout, emit `checked` with `probe_outcome: "failed"` and
**leave the cache file untouched** — do not restamp `checked_at`. On success,
`plugin_currency_cache_write` and emit `checked` with `probe_outcome: "ok"`.

Surfacing, governed by the age rule:

`skipped` and `stale` are orthogonal and both can fire in one run: `skipped`
records that no probe happened, `stale` records that findings exist. A fresh
cache holding findings therefore emits `skipped`/`cache_fresh` **and** `stale`.
Only `checked` is mutually exclusive with `skipped`/`cache_fresh`.

- Fresh cache with findings → emit `stale`, inject one line naming the condition,
  the answer age, and `/plugin` as the remedy, clipped to `max_pointer_chars`.
- Fresh cache, no findings → inject nothing unless `surface_when_current` is true.
- Not fresh → inject "unchecked for Nh". Never the word "current".

Emit with the substrate's own path, matching `session_tracker_emit`
(`scripts/lib/session-tracker.sh:251`): build params with `jq -n`, pipe to
`onlooker-event.mjs emit`, then `onlooker_append_event`.

Always print a valid `hookSpecificOutput` envelope even when injecting nothing,
as `curator-session-start.sh` does. Exit 0 on every path.

- [ ] **Step 5: Run to verify they pass**

Run: `bats test/bats/plugin-currency-surfacer.bats`
Expected: PASS, all six.

- [ ] **Step 6: Register the hook**

In `hooks/hooks.json`, append to the `SessionStart` matcher `*` array:

```json
      {
        "type": "command",
        "command": "\"$CLAUDE_PLUGIN_ROOT\"/scripts/hooks/plugin-currency-surfacer.sh"
      }
```

- [ ] **Step 7: Triage the three types into bus coverage**

In `test/bus-coverage.json`, add all three to `expected` — every one is driven by
a test in Step 2. `npm run test:bus` fails on any registered type in neither list.

- [ ] **Step 8: Run the full suite**

```bash
npm run test:bats
npm run test:schema
npm run test:bus
npm run test:shellcheck
```

Run `test:bats` on its own rather than inside `npm run test:ci`: its bats leg has
twice exceeded a 10-minute window, and a timeout there reads like a failure when
it is not.

Expected: 1,565+ bats passing with the new files, 166+ node, bus clean,
shellcheck clean. Shellcheck reports ungated non-final `[[ ]]` and `!` in bats as
SC2314 — fix any it finds rather than suppressing them.

- [ ] **Step 9: Commit and open the PR**

Use the `/commit` skill, then `/git-workflow:pr`. Wait for CI before merging.

---

## Out of scope, deliberately

Recorded so a reviewer does not read these as omissions:

- **`lint:plugin-installs` still does not join `test:ci`.** The decision and its
  evidence are in the spec and on `ecosystem-449.59`.
- **Fresh-worktree snapshot behavior.** A new worktree freezes at whatever the
  clone held at creation time. This surface makes it visible; fixing it is a
  separate bead.
- **Automatic remediation.** There is no non-interactive install path. The hook
  reports and stops.
- **Today's staleness.** The bootstrap limit: a check shipped in 0.55.0 does not
  exist in a session running 0.54.4.
