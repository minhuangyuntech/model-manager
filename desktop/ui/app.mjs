import { compareInventory } from './inventory.mjs';

const $ = id => document.getElementById(id);
const labels = {
  custom: '自訂資料夾', ollama: 'Ollama', lmStudio: 'LM Studio',
  huggingFace: 'Hugging Face', comfyUi: 'ComfyUI',
};
const { invoke } = window.__TAURI__.core;
const settingsKey = 'local-model-manager.sources.v1';
const pageSize = 150;
const decimal = new Intl.NumberFormat('zh-Hant', { maximumFractionDigits: 1 });
let sources = [];
let reports = [];
let baseline = new Map();
let rows = [];
let limit = pageSize;
let busy = false;

function element(tag, text) {
  const node = document.createElement(tag);
  node.textContent = text;
  return node;
}

function setBusy(value) {
  busy = value;
  for (const button of [$('refresh'), $('add'), ...$('sources').querySelectorAll('button')]) {
    button.disabled = value;
  }
}

function showError(message) {
  $('error').hidden = !message;
  $('error').textContent = message;
}

function saveSources(next) {
  localStorage.setItem(settingsKey, JSON.stringify(next));
  sources = next;
  renderSources();
}

function renderSources() {
  const list = $('sources');
  list.replaceChildren();
  sources.forEach((source, index) => {
    const item = element('li', '');
    const text = element('span', `${labels[source.provider]} · ${source.path}`);
    const button = element('button', '移除來源');
    button.type = 'button';
    button.disabled = busy;
    button.setAttribute('aria-label', `移除來源：${source.path}`);
    button.addEventListener('click', () => {
      try {
        saveSources(sources.filter((_, i) => i !== index));
        refresh();
      } catch (error) { showError(`無法儲存來源：${error}`); }
    });
    item.append(text, button);
    list.append(item);
  });
  if (!sources.length) list.append(element('li', '尚未設定來源。'));
}

function sizeText(bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB'];
  let i = 0;
  while (bytes >= 1024 && i < units.length - 1) { bytes /= 1024; i++; }
  return `${decimal.format(bytes)} ${units[i]}`;
}

function renderModels() {
  const provider = $('filter').value;
  const needle = $('search').value.trim().toLowerCase();
  const filtered = rows.filter(row => (!provider || row.source.provider === provider) && row.search.includes(needle));
  const fragment = document.createDocumentFragment();
  for (const { source, model } of filtered.slice(0, limit)) {
    const row = element('tr', '');
    const modelCell = element('td', '');
    modelCell.append(element('strong', model.name), element('small', model.path));
    row.append(modelCell, element('td', labels[source.provider]), element('td', model.category),
      element('td', sizeText(model.bytes)),
      element('td', model.modified === null ? '—' : new Date(model.modified).toLocaleString('zh-TW')));
    fragment.append(row);
  }
  if (!filtered.length) {
    const row = element('tr', '');
    const empty = element('td', rows.length ? '沒有符合搜尋條件的模型。' : '清單目前沒有模型。');
    empty.colSpan = 5;
    row.append(empty);
    fragment.append(row);
  }
  $('models').replaceChildren(fragment);
  $('model-count').textContent = `${filtered.length} / ${rows.length} 個模型`;
  $('more').hidden = filtered.length <= limit;
}

function renderResults(scannedSources, changes) {
  rows = reports.flatMap((report, index) => report.models.map(model => {
    const source = scannedSources[index];
    return { source, model, search: `${model.name} ${model.format} ${model.category} ${model.path}`.toLowerCase() };
  })).sort((a, b) => a.model.name.localeCompare(b.model.name, 'zh-Hant', { numeric: true }));
  limit = pageSize;
  renderModels();

  const groups = [['新增', changes.added], ['移除', changes.removed], ['變更', changes.modified]];
  $('changes').hidden = false;
  $('change-summary').textContent = groups.map(([kind, models]) => `${kind} ${models.length}`).join(' · ');
  const allChanges = groups.flatMap(([kind, models]) => models.map(({ model }) => `${kind}：${model.name} · ${model.path}`));
  $('change-list').replaceChildren(...allChanges.slice(0, 100).map(text => element('li', text)));
  if (allChanges.length > 100) $('change-list').append(element('li', `另有 ${allChanges.length - 100} 筆未顯示。`));
  if (!allChanges.length) $('change-list').append(element('li', '未偵測到變更；首次成功掃描只建立比較基準。'));

  const warnings = reports.flatMap(({ warnings, omitted_warnings }) => omitted_warnings ? [...warnings, `此來源另有 ${omitted_warnings} 個掃描提示。`] : warnings);
  $('warnings').hidden = !warnings.length;
  const warningTotal = reports.reduce((sum, report) => sum + report.warnings.length + report.omitted_warnings, 0);
  $('warning-summary').textContent = `${warningTotal} 個掃描提示：受影響來源可能只顯示部分結果，不列入變更比較`;
  $('warning-list').replaceChildren(...warnings.map(text => element('li', text)));
}

async function refresh() {
  if (busy) return;
  setBusy(true);
  showError('');
  $('status').textContent = '正在掃描本機資料夾…';
  try {
    const scannedSources = sources;
    const result = await invoke('scan_sources', { sources: scannedSources });
    const comparison = compareInventory(scannedSources, result, baseline);
    reports = result;
    renderResults(scannedSources, comparison.changes);
    baseline = comparison.baseline;
    $('last-scan').textContent = `上次掃描完成：${new Date().toLocaleString('zh-TW')}`;
    $('status').textContent = reports.some(report => report.warnings.length) ? '掃描結束；部分來源有讀取問題。' : '掃描完成。';
  } catch (error) {
    $('status').textContent = '掃描失敗；保留上次顯示的結果。';
    showError(`無法重新掃描：${error}`);
  } finally { setBusy(false); }
}

async function addSource() {
  if (busy) return;
  setBusy(true);
  showError('');
  let added = false;
  try {
    const source = await invoke('choose_source', { provider: $('provider').value });
    if (!source) return;
    if (sources.some(existing => existing.path === source.path)) {
      showError('這個資料夾已經加入。');
      return;
    }
    saveSources([...sources, source]);
    added = true;
  } catch (error) { showError(`無法加入來源：${error}`); }
  finally { setBusy(false); }
  if (added) refresh();
}

function validSources(value) {
  return Array.isArray(value) && value.every(source => source && typeof source.path === 'string' &&
    typeof source.provider === 'string' && Object.hasOwn(labels, source.provider));
}

async function start() {
  for (const [provider, label] of Object.entries(labels)) {
    $('filter').add(new Option(label, provider));
    if (provider !== 'custom') $('provider').add(new Option(label, provider));
  }
  $('refresh').addEventListener('click', refresh);
  $('add').addEventListener('click', addSource);
  for (const id of ['search', 'filter']) $(id).addEventListener('input', () => { limit = pageSize; renderModels(); });
  $('more').addEventListener('click', () => { limit += pageSize; renderModels(); });
  try {
    const saved = localStorage.getItem(settingsKey);
    const initial = saved === null ? await invoke('default_sources') : JSON.parse(saved);
    if (!validSources(initial)) throw new Error('來源設定格式不正確。');
    sources = initial;
  } catch (error) {
    $('status').textContent = '載入來源失敗；可手動加入資料夾。';
    showError(`無法載入來源：${error}`);
    renderSources();
    setBusy(false);
    return;
  }
  renderSources();
  refresh();
}

start();
