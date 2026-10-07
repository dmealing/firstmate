#!/usr/bin/env bash
# Portable checks for the Claude Code usage-line mod (.claude/mods/firstmate-usage-line)
# that need no Claude Code binary, so CI enforces them wherever Node runs: the plugin's
# declared shape (one hooks module, reached from the project's .claude/skills path, so
# it loads only in sessions whose directory is this repository) and the pure line text.
# The engine-bound behavior runs under tests/fm-usage-line-mod-plugin.test.sh and the
# real TUI under tests/fm-usage-line-mod-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MOD="$ROOT/.claude/mods/firstmate-usage-line"
TMP_ROOT=$(fm_test_tmproot fm-usage-line-mod)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Claude Code usage-line mod checks"; exit 0; }

test_plugin_shape() {
  local link out
  link="$ROOT/.agents/skills/firstmate-usage-line"
  [ -L "$link" ] || fail "the usage-line mod is not linked into .agents/skills, so Claude Code's project skills-dir scan cannot adopt it"
  [ "$(cd "$link" && pwd -P)" = "$(cd "$MOD" && pwd -P)" ] || fail "the .agents/skills/firstmate-usage-line link does not resolve to the mod"
  [ -f "$ROOT/.claude/skills/firstmate-usage-line/hooks/hooks.json" ] || fail "the project's .claude/skills path does not reach the mod's hooks module"
  [ ! -e "$MOD/SKILL.md" ] || fail "the mod carries a SKILL.md and would load as a skill on every harness"
  cat >"$TMP_ROOT/shape.mjs" <<JS
import { readFileSync } from "node:fs";
const mod = ${MOD@Q};
const manifest = JSON.parse(readFileSync(\`\${mod}/.claude-plugin/plugin.json\`, "utf8"));
if (manifest.name !== "firstmate-usage-line") throw new Error(\`manifest name \${manifest.name}\`);
for (const key of ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "outputStyles"]) {
  if (key in manifest) throw new Error(\`manifest declares \${key}\`);
}
const hooks = JSON.parse(readFileSync(\`\${mod}/hooks/hooks.json\`, "utf8"));
if (JSON.stringify(Object.keys(hooks).sort()) !== JSON.stringify(["description", "modules"])) throw new Error("hooks.json declares more than one hooks module");
JS
  out=$(node --input-type=module <"$TMP_ROOT/shape.mjs" 2>&1) || fail "plugin shape: $out"
  pass "the usage-line mod is one hooks module reached only through this repository's .claude/skills path"
}

test_line_text() {
  local out
  cat >"$TMP_ROOT/line.mjs" <<JS
import { pathToFileURL } from "node:url";
const lib = await import(pathToFileURL(${MOD@Q} + "/lib/fm-usage-line.ts").href);
const check = (actual, expected) => { if (actual !== expected) throw new Error(\`got \${JSON.stringify(actual)}, want \${JSON.stringify(expected)}\`); };
check(lib.usageLine({ context: { percent: 42 }, rateLimits: [
  { kind: "five_hour", percentUsed: 63.4, resetsAt: "2026-10-07T03:00:00Z" },
  { kind: "seven_day", percentUsed: 81, resetsAt: "2026-10-09T18:00:00" },
] }), "context 42% · 5h quota 63% · week 81% (resets Oct 9, 6pm)");
check(lib.usageLine({ context: {}, rateLimits: [] }), undefined);
check(lib.resetLabel("2026-01-02T00:30:00"), "Jan 2, 12:30am");
check(lib.usageNotice("x").type, "system");
JS
  out=$(node --input-type=module <"$TMP_ROOT/line.mjs" 2>&1) || fail "line text: $out"
  pass "the usage line reads context, each plan-limit window, and the weekly reset, and is carried as a system notice"
}

test_plugin_shape
test_line_text
