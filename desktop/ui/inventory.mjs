export const sourceKey = source => JSON.stringify([source.provider, source.path]);

// Keep the last successful snapshot of each source. An unreadable disk isn't a deletion.
export function compareInventory(sources, reports, previous) {
  const baseline = new Map();
  const changes = { added: [], removed: [], modified: [] };
  for (const [index, source] of sources.entries()) {
    const { models, warnings } = reports[index];
    const key = sourceKey(source);
    const before = previous.get(key);
    if (warnings.length) {
      if (before) baseline.set(key, before);
      continue;
    }
    const after = new Map(models.map(model => [model.relativePath, model]));
    baseline.set(key, after);
    if (!before) continue;
    for (const [path, model] of after) {
      const old = before.get(path);
      if (!old) changes.added.push({ source, model });
      else if (model.bytes !== old.bytes || model.modified !== old.modified ||
               model.category !== old.category || model.format !== old.format || model.name !== old.name) {
        changes.modified.push({ source, model });
      }
    }
    for (const [path, model] of before) {
      if (!after.has(path)) changes.removed.push({ source, model });
    }
  }
  return { baseline, changes };
}