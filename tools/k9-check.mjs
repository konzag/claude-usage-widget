#!/usr/bin/env node
// K9 template check (plan K9, 2026-11-16): fails when this repo lacks one of the test/quality items every app or
// game must have. CANONICAL COPY: konzag/template-app (apps) and konzag/games-template (games) hold the same file
// and its tests (tools/k9-check.test.mjs); every repo copies both verbatim. Change it there first, then re-copy.
//
// Usage: node tools/k9-check.mjs [--root <dir>] [--ref <git-ref>] [--json]
//   --root  repo to check (default: cwd). In a git checkout only tracked files count (git ls-files).
//   --ref   check a commit instead of the working tree (git ls-tree + cat-file; nothing is checked out).
//   --json  print the report as JSON (for inventories).
//   --kind  app|game, only for a repo without k9-allowlist.json yet (inventory); the file wins when it exists.
// Config: k9-allowlist.json at the repo root, {"kind": "app"|"game", "allow": {"<item>": "<reason>"}}.
//   An allowlisted item that is missing is report-only (::warning::, exit 0): the gap stays visible, never faked.
//   An allowlisted item that is present fails (ratchet: delete the entry). A reason must be a real sentence.
// Items:  app  = unit-tests api-tests e2e-playwright axe-2.2 visual-baseline coverage-floor el-en-strings health-ready
//         game = unit-tests e2e-playwright axe-2.2 visual-baseline coverage-floor el-en-strings readme-test-guide
// Exit:   0 all present or allowlisted, 1 an item missing (or stale allowlist entry), 2 config/usage error.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const ITEMS = {
  app: ['unit-tests', 'api-tests', 'e2e-playwright', 'axe-2.2', 'visual-baseline', 'coverage-floor', 'el-en-strings',
    'health-ready'],
  game: ['unit-tests', 'e2e-playwright', 'axe-2.2', 'visual-baseline', 'coverage-floor', 'el-en-strings',
    'readme-test-guide'],
};
const CONFIG = 'k9-allowlist.json';
const MAX_BYTES = 2 * 1024 * 1024;
// The K9 files themselves never count (their test fixtures name every item).
const IGNORED = /(^|\/)tools\/k9-check(\.test)?\.mjs$|(^|\/)(node_modules|\.git|\.venv|venv|dist|build|vendor|site-packages|playwright-report|test-results)\//;
const TEXT_EXT = /\.(py|m?js|cjs|ts|tsx|jsx|html?|json|ya?ml|toml|ini|cfg|ps1|psm1|md)$/i;
const SRC_EXT = /\.(py|m?js|cjs|ts|tsx|jsx|html?|json|ps1|psm1)$/i;
const TEST_PATH = /(^|\/)(tests?|e2e|ui-tests|__tests__)\/|(^|\/)test_[^/]*\.py$|_test\.py$|\.(test|spec)\.(m?js|cjs|ts|tsx)$|\.Tests\.ps1$/i;
const UNIT_FILE = /(^|\/)test_[^/]*\.py$|_test\.py$|\.test\.(m?js|cjs|ts|tsx)$|\.Tests\.ps1$|(^|\/)tests\/[^/]*\.ps1$|(^|\/)tests\/unit\//i;
const HTTP_CLIENT = /\b(TestClient|AsyncClient|ASGITransport|supertest)\b|\bclient\.(get|post|put|patch|delete|head|options)\(/;
const PLAYWRIGHT = /@playwright\/test/;
const PW_CONFIG = /(^|\/)playwright\.config\.(m?js|cjs|ts)$/;
const AXE = /AxeBuilder|@axe-core|axe-playwright|axe_playwright|injectAxe|checkA11y/;
const SCREENSHOT = /\.(toHaveScreenshot|toMatchSnapshot)\(/;
const BASELINE_PNG = /(-snapshots|__screenshots__|__snapshots__|(^|\/)snapshots)\/.+\.png$/i;
const FLOOR_FILES = ['.coverage-floor', '.coveragerc', 'pyproject.toml', 'pytest.ini', 'setup.cfg', 'package.json'];
const LOCALE_FILE = /(^|\/)(el|en)(_[A-Z]{2})?\.(json|js|mjs|ts|po|ya?ml)$/;
const HEALTH = /["'`](?:[^"'`\s]*\/)?(?:health|healthz|livez|live)["'`]/;
const READY = /["'`](?:[^"'`\s]*\/)?(?:ready|readyz)["'`]/;
const README_SECTIONS = ['Οθόνες και ροή', 'Λίστα χειροκίνητων δοκιμών', 'Τι άλλαξε στην τελευταία έκδοση',
  'Γνωστοί περιορισμοί', 'Ασφαλής δοκιμή', 'Αναφορά προβλήματος'];

class ConfigError extends Error {}

function parseArgs(argv) {
  const opts = { root: process.cwd(), ref: null, json: false, kind: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') opts.json = true;
    else if (a === '--root' && argv[i + 1]) opts.root = argv[++i];
    else if (a === '--ref' && argv[i + 1]) opts.ref = argv[++i];
    else if (a === '--kind' && argv[i + 1]) opts.kind = argv[++i];
    else throw new ConfigError(`unknown argument: ${a}`);
  }
  return opts;
}

function git(root, args, input) {
  return spawnSync('git', ['-C', root, ...args], { input, maxBuffer: 512 * 1024 * 1024 });
}

// The repo as a list of paths + a reader: the working tree (tracked files), a plain directory, or a commit.
function openRepo(root, ref) {
  if (ref) {
    const ok = git(root, ['rev-parse', '-q', '--verify', `${ref}^{commit}`]);
    if (ok.status !== 0) throw new ConfigError(`ref not found: ${ref}`);
    const ls = git(root, ['ls-tree', '-r', '-z', '--name-only', ref]);
    const files = ls.stdout.toString('utf8').split('\0').filter(Boolean);
    const cache = new Map();
    const want = files.filter(f => TEXT_EXT.test(f) || FLOOR_FILES.includes(f) || f === CONFIG);
    const out = git(root, ['cat-file', '--batch'], want.map(f => `${ref}:${f}`).join('\n') + '\n').stdout;
    let pos = 0;
    for (const f of want) {
      const nl = out.indexOf(10, pos);
      const header = out.subarray(pos, nl).toString('utf8');
      const m = /^\S+ blob (\d+)$/.exec(header);
      if (!m) { pos = nl + 1; continue; }
      const size = Number(m[1]);
      cache.set(f, out.subarray(nl + 1, nl + 1 + size).toString('utf8'));
      pos = nl + 1 + size + 1;
    }
    return { files, read: f => cache.get(f) ?? null };
  }
  let files;
  const inside = git(root, ['rev-parse', '--is-inside-work-tree']);
  if (inside.status === 0 && inside.stdout.toString().trim() === 'true') {
    const ls = git(root, ['ls-files', '-z']);
    files = ls.stdout.toString('utf8').split('\0').filter(Boolean);
  } else {
    files = [];
    const walk = rel => {
      for (const e of fs.readdirSync(path.join(root, rel), { withFileTypes: true })) {
        const p = rel ? `${rel}/${e.name}` : e.name;
        if (e.isDirectory()) { if (!IGNORED.test(`${p}/`)) walk(p); } else files.push(p);
      }
    };
    walk('');
  }
  return {
    files,
    read: f => {
      try {
        const buf = fs.readFileSync(path.join(root, f));  // read once, then size-check (no stat-then-read race)
        return buf.length > MAX_BYTES ? null : buf.toString('utf8');
      } catch { return null; }
    },
  };
}

function loadConfig(repo, kind) {
  const raw = repo.read(CONFIG);
  if (raw === null && kind) {  // inventory of a repo that has no config yet: nothing allowlisted
    if (!ITEMS[kind]) throw new ConfigError(`--kind must be "app" or "game", got ${JSON.stringify(kind)}`);
    return { kind, allow: {} };
  }
  if (raw === null) throw new ConfigError(`${CONFIG} not found (copy it from the template and set "kind")`);
  let cfg;
  try { cfg = JSON.parse(raw); } catch (e) { throw new ConfigError(`${CONFIG} is not valid JSON: ${e.message}`); }
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) throw new ConfigError(`${CONFIG} must be an object`);
  for (const k of Object.keys(cfg)) {
    if (!['kind', 'allow', '$comment'].includes(k)) throw new ConfigError(`${CONFIG}: unknown key "${k}"`);
  }
  if (!ITEMS[cfg.kind]) throw new ConfigError(`${CONFIG}: "kind" must be "app" or "game", got ${JSON.stringify(cfg.kind)}`);
  const allow = cfg.allow ?? {};
  if (typeof allow !== 'object' || Array.isArray(allow)) throw new ConfigError(`${CONFIG}: "allow" must be an object`);
  for (const [item, reason] of Object.entries(allow)) {
    if (!ITEMS[cfg.kind].includes(item)) {
      throw new ConfigError(`${CONFIG}: "${item}" is not a K9 item for kind ${cfg.kind} (${ITEMS[cfg.kind].join(', ')})`);
    }
    if (typeof reason !== 'string' || reason.trim().length < 15) {
      throw new ConfigError(`${CONFIG}: allow["${item}"] needs a written reason (at least 15 characters)`);
    }
  }
  return { kind: cfg.kind, allow };
}

function floorIn(name, text) {
  if (name === '.coverage-floor') return text.match(/^\s*(\d+(?:\.\d+)?)/m)?.[1] ?? null;
  const live = text.split(/\r?\n/).filter(l => !/^\s*[#;]/.test(l)).join('\n');
  return live.match(/(?:fail_under\s*=\s*|--cov-fail-under[= ]|--test-coverage-lines[= ])(\d+(?:\.\d+)?)/)?.[1] ?? null;
}

// One language's strings: an object key (`el: {`, `"en": "..."`, `en: Object.freeze(en)`) or a table
// (`const en = {`). An i18n/strings/locale module that names both codes as quoted literals also counts.
const LANG = {
  el: [/(?:^|[\s{,([])["']?el["']?\s*:\s*[\w{["'`]/m, /\b(?:const|let|var)\s+el\s*=\s*(?:Object\.freeze\()?\{/],
  en: [/(?:^|[\s{,([])["']?en["']?\s*:\s*[\w{["'`]/m, /\b(?:const|let|var)\s+en\s*=\s*(?:Object\.freeze\()?\{/],
};
function hasLang(text, key) {
  return LANG[key].some(re => re.test(text));
}
const I18N_MODULE = /(^|\/)(i18n|l10n|strings|locales?|translations?|messages)(\.[a-z]+)?\.(py|m?js|cjs|ts)$|(^|\/)(i18n|locales?)\//i;
function bothLangs(file, text) {
  if (hasLang(text, 'el') && hasLang(text, 'en')) return true;
  return I18N_MODULE.test(file) && /["']el["']/.test(text) && /["']en["']/.test(text);
}

function detect(repo, kind) {
  const files = repo.files.filter(f => !IGNORED.test(f));
  const read = f => repo.read(f) ?? '';
  const tests = files.filter(f => TEST_PATH.test(f) && TEXT_EXT.test(f));
  const sources = files.filter(f => !TEST_PATH.test(f) && SRC_EXT.test(f) && !/(^|\/)package(-lock)?\.json$/.test(f)
    && !/^docs\//.test(f));
  const testText = new Map(tests.map(f => [f, read(f)]));
  const browserTests = tests.filter(f => PLAYWRIGHT.test(testText.get(f)));
  const has = (list, re) => list.filter(f => re.test(testText.get(f) ?? read(f)));

  const evidence = {};
  const unit = files.filter(f => UNIT_FILE.test(f)).filter(f => {
    const t = testText.get(f) ?? read(f);
    return !PLAYWRIGHT.test(t) && !HTTP_CLIENT.test(t);
  });
  evidence['unit-tests'] = unit;
  evidence['api-tests'] = has(tests.filter(f => !PLAYWRIGHT.test(testText.get(f))), HTTP_CLIENT);
  const configs = files.filter(f => PW_CONFIG.test(f));
  const pages = browserTests.filter(f => /\bpage\b/.test(testText.get(f)));
  evidence['e2e-playwright'] = configs.length && pages.length ? [...configs, ...pages] : [];
  evidence['axe-2.2'] = tests.filter(f => AXE.test(testText.get(f)) && /wcag22aa/.test(testText.get(f)));
  const shots = has(browserTests, SCREENSHOT);
  const pngs = files.filter(f => BASELINE_PNG.test(f));
  evidence['visual-baseline'] = shots.length && pngs.length ? [...shots, `${pngs.length} baseline png`] : [];
  evidence['coverage-floor'] = FLOOR_FILES.filter(f => files.includes(f))
    .map(f => [f, floorIn(f, read(f))]).filter(([, v]) => v !== null && Number(v) > 0).map(([f, v]) => `${f}=${v}`);
  const locales = files.filter(f => LOCALE_FILE.test(f));
  const pair = locales.filter(f => locales.includes(f.replace(/(^|\/)el(_[A-Z]{2})?\./, '$1en.').replace(/(^|\/)en_[A-Z]{2}\./, '$1en.'))
    && /(^|\/)el(_[A-Z]{2})?\./.test(f));
  const inline = sources.filter(f => /\.(py|m?js|cjs|ts|tsx|jsx|html?|ps1|psm1)$/i.test(f))
    .filter(f => bothLangs(f, read(f)));
  evidence['el-en-strings'] = pair.length ? pair : inline;
  const hs = sources.filter(f => HEALTH.test(read(f)));
  const rs = sources.filter(f => READY.test(read(f)));
  evidence['health-ready'] = hs.length && rs.length ? [...new Set([...hs, ...rs])] : [];
  const readme = read('README.md');
  const headings = [...readme.matchAll(/^##+ (.+)$/gm)].map(m => m[1].trim());
  const sectionsOk = README_SECTIONS.every(s => headings.some(h => h.startsWith(s)));
  const idsOk = /^\|\s*[A-Z]{2,5}-\d{2,3}\s*\|/m.test(readme);
  const forms = ['bug.yml', 'update.yml'].every(f => files.includes(`.github/ISSUE_TEMPLATE/${f}`));
  evidence['readme-test-guide'] = sectionsOk && idsOk && forms ? ['README.md', '.github/ISSUE_TEMPLATE/'] : [];

  return ITEMS[kind].map(item => ({ item, evidence: evidence[item].slice(0, 5) }));
}

function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
    const repo = openRepo(path.resolve(opts.root), opts.ref);
    const { kind, allow } = loadConfig(repo, opts.kind);
    let rc = 0;
    const items = detect(repo, kind).map(({ item, evidence }) => {
      const present = evidence.length > 0;
      const reason = allow[item];
      let status;
      if (present && reason) { status = 'stale-allowlist'; rc = 1; }
      else if (present) status = 'present';
      else if (reason) status = 'allowlisted';
      else { status = 'missing'; rc = 1; }
      return { item, status, evidence, ...(reason ? { reason } : {}) };
    });
    if (opts.json) {
      console.log(JSON.stringify({ kind, ok: rc === 0, items }, null, 2));
    } else {
      for (const i of items) {
        if (i.status === 'present') console.log(`K9 ${i.item}: present (${i.evidence.join(', ')})`);
        else if (i.status === 'allowlisted') console.log(`::warning::K9 ${i.item}: missing, allowlisted (report-only): ${i.reason}`);
        else if (i.status === 'stale-allowlist') {
          console.log(`::error::K9 ${i.item}: present but still allowlisted in ${CONFIG}: delete the entry (ratchet)`);
        } else console.log(`::error::K9 ${i.item}: missing (add it, or list it in ${CONFIG} "allow" with a reason)`);
      }
      const gaps = items.filter(i => i.status === 'allowlisted').length;
      console.log(rc === 0 ? `K9 ${kind}: ok (${items.length - gaps} present, ${gaps} allowlisted)` : `K9 ${kind}: FAILED`);
    }
    process.exitCode = rc;
  } catch (e) {
    if (!(e instanceof ConfigError)) throw e;
    console.log(`::error::K9 config: ${e.message}`);
    process.exitCode = 2;
  }
}

main();
