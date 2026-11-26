import assert from 'node:assert/strict';
import { test } from 'node:test';
import { compareInventory } from '../ui/inventory.mjs';

const source = { provider: 'custom', path: '/models' };
const other = { provider: 'custom', path: '/other' };
const model = (path, bytes = 1, modified = 10) => ({ relativePath: path, bytes, modified });
const report = (...models) => ({ models, warnings: [] });
const failed = { models: [], warnings: ['not readable'] };
const empty = { added: [], removed: [], modified: [] };

test('first scan is a baseline and subsequent scans detect local changes', () => {
  const before = compareInventory([source], [report(model('deleted'), model('resized'), model('retimed'))], new Map());
  assert.deepEqual(before.changes, empty);
  const latest = compareInventory([source], [report(model('added'), model('resized', 2), model('retimed', 1, 11))], before.baseline);
  assert.deepEqual(latest.changes.added.map(({ model }) => model.relativePath), ['added']);
  assert.deepEqual(latest.changes.removed.map(({ model }) => model.relativePath), ['deleted']);
  assert.deepEqual(latest.changes.modified.map(({ model }) => model.relativePath), ['resized', 'retimed']);
});

test('failed scan does not claim deletion or stop comparison for healthy sources', () => {
  const first = compareInventory([source, other], [report(model('existing')), report()], new Map());
  const incomplete = compareInventory([source, other], [failed, report(model('new'))], first.baseline);
  assert.deepEqual(incomplete.changes, { ...empty, added: [{ source: other, model: model('new') }] });
  const recovered = compareInventory([source, other], [report(), report(model('new'))], incomplete.baseline);
  assert.deepEqual(recovered.changes, { ...empty, removed: [{ source, model: model('existing') }] });
});

test('adding or removing a source is not counted as adding or removing files', () => {
  const first = compareInventory([source], [report(model('existing'))], new Map());
  const changed = compareInventory([other], [report(model('other'))], first.baseline);
  assert.deepEqual(changed.changes, empty);
  assert.equal(changed.baseline.size, 1);
});
