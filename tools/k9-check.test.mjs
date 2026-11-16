// Tests for tools/k9-check.mjs (plan K9 template check). Run: node --test tools/k9-check.test.mjs
// CANONICAL COPY: konzag/template-app (apps) and konzag/games-template (games) hold the same two files; every repo
// copies both verbatim. Fixtures live in the OS temp dir (never under this repo), git fixtures are pinned with
// GIT_CEILING_DIRECTORIES + an explicit GIT_DIR so a fixture can never commit into the real clone.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'k9-check.mjs');

const SPEC = `import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
test('home', async ({ page }) => {
  await page.goto('/');
  const r = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze();
  expect(r.violations).toEqual([]);
  await expect(page).toHaveScreenshot('home.png');
});
`;

const APP = {
  'tests/test_service.py': 'def test_add():\n    assert 1 + 1 == 2\n',
  'tests/test_api.py':
    'from fastapi.testclient import TestClient\nfrom app.main import app\n\nclient = TestClient(app)\n\n' +
    'def test_health():\n    assert client.get("/health/live").status_code == 200\n',
  'ui-tests/playwright.config.mjs': "export default { testDir: '.' };\n",
  'ui-tests/ui.spec.mjs': SPEC,
  'ui-tests/ui.spec.mjs-snapshots/home-chromium-linux.png': 'PNG',
  '.coveragerc': '[report]\nfail_under = 95\n',
  'app/i18n/el.json': '{"hi": "Γεια"}\n',
  'app/i18n/en.json': '{"hi": "Hi"}\n',
  'app/api/health.py': '@router.get("/health/live")\nasync def live(): ...\n@router.get("/health/ready")\nasync def ready(): ...\n',
};

const README = `# Game
## Η ιστορία
## Οθόνες και ροή
## Λίστα χειροκίνητων δοκιμών
| ID | βήματα |
|---|---|
| GG-01 | ανοίγει |
## Τι άλλαξε στην τελευταία έκδοση
## Γνωστοί περιορισμοί
## Ασφαλής δοκιμή
## Αναφορά προβλήματος
`;

const GAME = {
  'tests/logic.test.mjs': "import { test } from 'node:test';\ntest('adds', () => {});\n",
  'playwright.config.ts': 'export default {};\n',
  'tests/smoke.spec.ts': SPEC,
  'tests/smoke.spec.ts-snapshots/home-desktop-linux.png': 'PNG',
  '.coverage-floor': '42\n',
  'index.html': "<script>const STR = { el: { start: 'Παίξε' }, en: { start: 'Play' } };</script>\n",
  'README.md': README,
  '.github/ISSUE_TEMPLATE/bug.yml': 'labels: [bug]\n',
  '.github/ISSUE_TEMPLATE/update.yml': 'labels: [update]\n',
};

const APP_ITEMS = ['unit-tests', 'api-tests', 'e2e-playwright', 'axe-2.2', 'visual-baseline', 'coverage-floor',
  'el-en-strings', 'health-ready'];
const GAME_ITEMS = ['unit-tests', 'e2e-playwright', 'axe-2.2', 'visual-baseline', 'coverage-floor', 'el-en-strings',
  'readme-test-guide'];

function fixture(files, config) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'k9-'));
  const all = { ...files };
  if (config !== undefined) all['k9-allowlist.json'] = typeof config === 'string' ? config : JSON.stringify(config);
  for (const [p, c] of Object.entries(all)) {
    if (c === null) continue;
    fs.mkdirSync(path.dirname(path.join(dir, p)), { recursive: true });
    fs.writeFileSync(path.join(dir, p), c);
  }
  return dir;
}

function run(dir, ...args) {
  const r = spawnSync(process.execPath, [SCRIPT, '--root', dir, ...args], {
    encoding: 'utf8',
    env: { ...process.env, GIT_CEILING_DIRECTORIES: path.dirname(dir) },
  });
  return { code: r.status, out: r.stdout + r.stderr };
}

function json(dir) {
  const r = run(dir, '--json');
  return { code: r.code, report: JSON.parse(r.out.slice(r.out.indexOf('{'), r.out.lastIndexOf('}') + 1)) };
}

// Files to drop so that exactly one item goes missing.
const DROP_APP = {
  'unit-tests': { 'tests/test_service.py': null },
  'api-tests': { 'tests/test_api.py': null },
  'e2e-playwright': { 'ui-tests/playwright.config.mjs': null },
  'axe-2.2': { 'ui-tests/ui.spec.mjs': SPEC.replace(", 'wcag22aa'", '') },
  'visual-baseline': { 'ui-tests/ui.spec.mjs-snapshots/home-chromium-linux.png': null },
  'coverage-floor': { '.coveragerc': '[report]\nshow_missing = True\n' },
  'el-en-strings': { 'app/i18n/en.json': null },
  'health-ready': { 'app/api/health.py': '@router.get("/health/live")\nasync def live(): ...\n' },
};
const DROP_GAME = {
  'unit-tests': { 'tests/logic.test.mjs': null },
  'e2e-playwright': { 'playwright.config.ts': null },
  'axe-2.2': { 'tests/smoke.spec.ts': SPEC.replace(", 'wcag22aa'", '') },
  'visual-baseline': { 'tests/smoke.spec.ts': SPEC.replace("await expect(page).toHaveScreenshot('home.png');", '') },
  'coverage-floor': { '.coverage-floor': null },
  'el-en-strings': { 'index.html': "<script>const STR = { el: { start: 'Παίξε' } };</script>\n" },
  'readme-test-guide': { 'README.md': README.replace('## Ασφαλής δοκιμή\n', '') },
};

test('a complete app passes with every item present', () => {
  const { code, report } = json(fixture(APP, { kind: 'app', allow: {} }));
  assert.equal(code, 0);
  assert.deepEqual(report.items.map(i => i.item), APP_ITEMS);
  for (const i of report.items) assert.equal(i.status, 'present', i.item);
});

test('a complete game passes with every item present (no API or health items for games)', () => {
  const { code, report } = json(fixture(GAME, { kind: 'game', allow: {} }));
  assert.equal(code, 0);
  assert.deepEqual(report.items.map(i => i.item), GAME_ITEMS);
  for (const i of report.items) assert.equal(i.status, 'present', i.item);
});

for (const [item, drop] of Object.entries(DROP_APP)) {
  test(`app without ${item}: fails and names it`, () => {
    const dir = fixture({ ...APP, ...drop }, { kind: 'app', allow: {} });
    const { code, out } = run(dir);
    assert.equal(code, 1, out);
    assert.match(out, new RegExp(`::error::K9 ${item.replace('.', '\\.')}: missing`));
    const { report } = json(dir);
    assert.deepEqual(report.items.filter(i => i.status !== 'present').map(i => i.item), [item]);
  });
}

for (const [item, drop] of Object.entries(DROP_GAME)) {
  test(`game without ${item}: fails and names it`, () => {
    const dir = fixture({ ...GAME, ...drop }, { kind: 'game', allow: {} });
    const { code, out } = run(dir);
    assert.equal(code, 1, out);
    const { report } = json(dir);
    assert.deepEqual(report.items.filter(i => i.status !== 'present').map(i => i.item), [item]);
  });
}

test('a missing item in the allowlist with a reason is report-only: warning, exit 0', () => {
  const reason = 'no screenshot baselines yet; tracked in TEST-MATRIX row visual regression';
  const dir = fixture({ ...APP, ...DROP_APP['visual-baseline'] }, { kind: 'app', allow: { 'visual-baseline': reason } });
  const { code, out } = run(dir);
  assert.equal(code, 0, out);
  assert.match(out, /::warning::K9 visual-baseline: missing, allowlisted \(report-only\): no screenshot baselines yet/);
  const { report } = json(dir);
  assert.equal(report.items.find(i => i.item === 'visual-baseline').status, 'allowlisted');
});

test('an allowlist entry for an item that is present fails (ratchet: remove the entry)', () => {
  const dir = fixture(APP, { kind: 'app', allow: { 'axe-2.2': 'old gap, closed since then by the new tags' } });
  const { code, out } = run(dir);
  assert.equal(code, 1, out);
  assert.match(out, /::error::K9 axe-2\.2: present but still allowlisted/);
});

test('an allowlist entry without a real reason is a config error (exit 2)', () => {
  for (const reason of ['', '   ', 'todo', 42]) {
    const dir = fixture({ ...APP, ...DROP_APP['axe-2.2'] }, { kind: 'app', allow: { 'axe-2.2': reason } });
    const { code, out } = run(dir);
    assert.equal(code, 2, `${JSON.stringify(reason)}: ${out}`);
  }
});

test('config errors exit 2: no file, bad JSON, unknown kind, unknown or not-applicable item', () => {
  assert.equal(run(fixture(APP)).code, 2);
  assert.equal(run(fixture(APP, '{ kind: app')).code, 2);
  assert.equal(run(fixture(APP, { kind: 'service', allow: {} })).code, 2);
  assert.equal(run(fixture(APP, { kind: 'app', allow: { 'unit-test': 'typo in the key must not hide a gap' } })).code, 2);
  assert.equal(run(fixture(GAME, { kind: 'game', allow: { 'health-ready': 'games have no health endpoint at all' } })).code, 2);
  assert.equal(run(fixture(APP, { kind: 'app', allow: {}, extra: 1 })).code, 2);
});

test('only the allowlisted gap is excused: a second missing item still fails', () => {
  const dir = fixture({ ...APP, ...DROP_APP['visual-baseline'], ...DROP_APP['axe-2.2'] },
    { kind: 'app', allow: { 'visual-baseline': 'no screenshot baselines yet in this repository' } });
  const { code, out } = run(dir);
  assert.equal(code, 1, out);
  assert.match(out, /::error::K9 axe-2\.2: missing/);
});

test('files under node_modules never count', () => {
  const files = { ...APP, 'tests/test_service.py': null, 'node_modules/x/tests/test_y.py': 'def test_y(): pass\n' };
  const { report } = json(fixture(files, { kind: 'app', allow: {} }));
  assert.equal(report.items.find(i => i.item === 'unit-tests').status, 'missing');
});

test('a coverage floor of 0 is no floor; pytest.ini --cov-fail-under and package.json forms count', () => {
  const zero = json(fixture({ ...APP, '.coveragerc': '[report]\nfail_under = 0\n' }, { kind: 'app', allow: {} }));
  assert.equal(zero.report.items.find(i => i.item === 'coverage-floor').status, 'missing');
  const commented = json(fixture({ ...APP, '.coveragerc': '[report]\n# fail_under = 95\n' }, { kind: 'app', allow: {} }));
  assert.equal(commented.report.items.find(i => i.item === 'coverage-floor').status, 'missing');
  const ini = json(fixture({ ...APP, '.coveragerc': null, 'pytest.ini': '[pytest]\naddopts = --cov=app --cov-fail-under=97\n' },
    { kind: 'app', allow: {} }));
  assert.equal(ini.code, 0);
});

test('inline EL+EN dictionaries count only when both languages are there', () => {
  const py = { ...APP, 'app/i18n/el.json': null, 'app/i18n/en.json': null,
    'app/strings.py': 'STRINGS = {\n    "el": {"hi": "Γεια"},\n    "en": {"hi": "Hi"},\n}\n' };
  assert.equal(json(fixture(py, { kind: 'app', allow: {} })).code, 0);
  const elOnly = { ...py, 'app/strings.py': 'STRINGS = {\n    "el": {"hi": "Γεια"},\n}\n' };
  assert.equal(json(fixture(elOnly, { kind: 'app', allow: {} })).report.items.find(i => i.item === 'el-en-strings').status,
    'missing');
});

test('strings or routes that only appear in tests do not count for the app', () => {
  const files = { ...APP, 'app/api/health.py': null, 'app/i18n/el.json': null, 'app/i18n/en.json': null,
    'tests/test_strings.py': 'S = {"el": {"a": "β"}, "en": {"a": "b"}}\nR = ["/health", "/ready"]\n' };
  const { report } = json(fixture(files, { kind: 'app', allow: {} }));
  assert.equal(report.items.find(i => i.item === 'el-en-strings').status, 'missing');
  assert.equal(report.items.find(i => i.item === 'health-ready').status, 'missing');
});

test('a README without a numbered test row or without the issue forms is no test guide', () => {
  const noIds = json(fixture({ ...GAME, 'README.md': README.replace('| GG-01 | ανοίγει |\n', '') }, { kind: 'game', allow: {} }));
  assert.equal(noIds.report.items.find(i => i.item === 'readme-test-guide').status, 'missing');
  const noForm = json(fixture({ ...GAME, '.github/ISSUE_TEMPLATE/update.yml': null }, { kind: 'game', allow: {} }));
  assert.equal(noForm.report.items.find(i => i.item === 'readme-test-guide').status, 'missing');
});

function git(dir, ...args) {
  const r = spawnSync('git', args, {
    cwd: dir, encoding: 'utf8',
    env: { ...process.env, GIT_DIR: path.join(dir, '.git'), GIT_WORK_TREE: dir, GIT_CEILING_DIRECTORIES: path.dirname(dir),
      GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.invalid', GIT_COMMITTER_NAME: 't',
      GIT_COMMITTER_EMAIL: 't@example.invalid' },
  });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}

test('in a git checkout only tracked files count; --ref reads a commit without checking it out', () => {
  const dir = fixture(APP, { kind: 'app', allow: {} });
  git(dir, 'init', '-q', '-b', 'main');
  git(dir, 'add', '-A');
  git(dir, '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'all');
  const full = git(dir, 'rev-parse', 'HEAD').trim();
  git(dir, 'rm', '-q', 'tests/test_service.py');
  git(dir, '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'drop unit');
  fs.mkdirSync(path.join(dir, 'tests'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'tests', 'test_service.py'), 'def test_untracked(): pass\n');  // untracked
  assert.equal(run(dir).code, 1, 'untracked file must not count');
  assert.equal(run(dir, '--ref', 'HEAD').code, 1);
  { const r = run(dir, '--ref', full); assert.equal(r.code, 0, r.out); }
  assert.equal(run(dir, '--ref', 'no-such-ref').code, 2);
});

test('the K9 files themselves never count as evidence (their fixtures name every item)', () => {
  const files = { 'tools/k9-check.test.mjs': fs.readFileSync(path.join(path.dirname(SCRIPT), 'k9-check.test.mjs'), 'utf8') };
  const { code, report } = json(fixture(files, { kind: 'app', allow: {} }));
  assert.equal(code, 1);
  for (const i of report.items) assert.equal(i.status, 'missing', i.item);
});

test('--kind lets an inventory run on a repo without a config; the config file still wins', () => {
  assert.equal(run(fixture(APP), '--kind', 'app').code, 0);
  assert.equal(run(fixture(APP), '--kind', 'robot').code, 2);
  const { report } = json(fixture(GAME, { kind: 'game', allow: {} }));
  assert.equal(report.kind, 'game');
  const r = run(fixture(GAME, { kind: 'game', allow: {} }), '--kind', 'app', '--json');
  assert.equal(JSON.parse(r.out).kind, 'game');
});

test('EL+EN as two tables (const el = {...}; const en = {...}) or an i18n module with both codes counts', () => {
  const base = { ...APP, 'app/i18n/el.json': null, 'app/i18n/en.json': null };
  const tables = { ...base, 'static/i18n.js': "const en = { hi: 'Hi' };\nconst el = { hi: 'Γεια' };\nconst M = { en, el };\n" };
  assert.equal(json(fixture(tables, { kind: 'app', allow: {} })).code, 0);
  const frozen = { ...base, 'static/app.js': 'const MESSAGES = Object.freeze({ en: Object.freeze(en), el: Object.freeze(el) });\n' };
  assert.equal(json(fixture(frozen, { kind: 'app', allow: {} })).code, 0);
  const pairs = { ...base, 'static/i18n.js': "var lang = stored === 'el' ? 'el' : 'en';\nvar T = { save: ['Save', 'Αποθήκευση'] };\n" };
  assert.equal(json(fixture(pairs, { kind: 'app', allow: {} })).code, 0);
  const dom = { ...base, 'static/app.js': "const el = document.getElementById('x');\nel.lang = 'en';\n" };
  assert.equal(json(fixture(dom, { kind: 'app', allow: {} })).report.items.find(i => i.item === 'el-en-strings').status,
    'missing');
});

// This repo's own wiring (not a fixture): a copy of the check must also run it. Every repo that copies these two
// files gets this pin for free: a CI workflow with one job that runs these tests and then the check, never
// conditional or continue-on-error, and a k9-allowlist.json whose reasons are real sentences.
test('this repo runs the K9 job in CI and has its allowlist', () => {
  const repo = path.resolve(path.dirname(SCRIPT), '..');
  const dir = path.join(repo, '.github', 'workflows');
  const jobs = fs.readdirSync(dir).filter(f => /\.ya?ml$/.test(f))
    .flatMap(f => fs.readFileSync(path.join(dir, f), 'utf8').replace(/\r\n/g, '\n').split(/^ {2}(?=[\w-]+:\n)/m));
  const k9 = jobs.filter(j => j.includes('node tools/k9-check.mjs'));
  assert.equal(k9.length, 1, 'exactly one CI job runs node tools/k9-check.mjs');
  const [job] = k9;
  assert.ok(job.indexOf('node --test tools/k9-check.test.mjs') > -1, 'the job runs the tests');
  assert.ok(job.indexOf('node --test tools/k9-check.test.mjs') < job.indexOf('node tools/k9-check.mjs'), 'tests first');
  assert.doesNotMatch(job, /^\s+if:/m, 'the job must not be conditional');
  assert.doesNotMatch(job, /continue-on-error/, 'report-only lives in k9-allowlist.json, never in CI');
  const cfg = JSON.parse(fs.readFileSync(path.join(repo, 'k9-allowlist.json'), 'utf8'));
  assert.ok(['app', 'game'].includes(cfg.kind));
});
