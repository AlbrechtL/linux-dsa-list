const DATA_DIR_CANDIDATES = [
  "../data/",
  "./data/",
];

const DATASET_MANIFEST_NAME = "datasets.json";

const CHIP_DELIMITER = "; ";

const state = {
  linuxVersion: "unknown",
  openwrtVersion: "unknown",
  generatedTag: "unknown",
  datasetOptions: [],
  selectedDatasetId: "",
  features: [],
  records: [],
  searchTerm: "",
  selectedFeatures: new Set(),
};

function parseVersionTuple(text) {
  const match = String(text || "").match(/^(\d+)\.(\d+)$/);
  if (!match) {
    return null;
  }
  return [Number(match[1]), Number(match[2])];
}

function compareVersionStringsDesc(a, b) {
  const pa = parseVersionTuple(a);
  const pb = parseVersionTuple(b);
  if (pa && pb) {
    if (pa[0] !== pb[0]) {
      return pb[0] - pa[0];
    }
    return pb[1] - pa[1];
  }
  return String(b).localeCompare(String(a));
}

function compareDatasetIds(a, b) {
  const aLinux = a.startsWith("linux_");
  const bLinux = b.startsWith("linux_");
  if (aLinux && !bLinux) {
    return -1;
  }
  if (!aLinux && bLinux) {
    return 1;
  }

  const aSnapshot = a.endsWith("_snapshot") || a === "snapshot";
  const bSnapshot = b.endsWith("_snapshot") || b === "snapshot";
  if (aSnapshot && !bSnapshot) {
    return -1;
  }
  if (!aSnapshot && bSnapshot) {
    return 1;
  }

  const aVer = a.includes("_") ? a.slice(a.indexOf("_") + 1) : a;
  const bVer = b.includes("_") ? b.slice(b.indexOf("_") + 1) : b;
  return compareVersionStringsDesc(aVer, bVer);
}

function datasetLabelFromId(id) {
  if (id.startsWith("linux_")) {
    return `Linux ${id.slice("linux_".length)}`;
  }
  if (id.startsWith("openwrt_")) {
    return `OpenWrt ${id.slice("openwrt_".length)}`;
  }
  return id;
}

function extractHrefTargets(htmlText) {
  const targets = [];
  const regex = /href\s*=\s*"([^"]+)"/gi;
  let match = regex.exec(htmlText);
  while (match) {
    targets.push(match[1]);
    match = regex.exec(htmlText);
  }
  return targets;
}

function normalizeHrefToName(href) {
  const raw = decodeURIComponent(String(href || ""));
  const noFragment = raw.split("#")[0];
  const noQuery = noFragment.split("?")[0];
  const trimmed = noQuery.replace(/\/+$/, "");
  if (!trimmed) {
    return "";
  }
  const parts = trimmed.split("/");
  return parts[parts.length - 1] || "";
}

async function fetchDirectoryListing(path) {
  try {
    const response = await fetch(path, { cache: "no-store" });
    if (!response.ok) {
      return null;
    }
    return await response.text();
  } catch {
    return null;
  }
}

async function fetchDatasetManifest(path) {
  try {
    const response = await fetch(path, { cache: "no-store" });
    if (!response.ok) {
      return null;
    }

    const payload = await response.json();
    if (!payload || !Array.isArray(payload.datasets)) {
      return null;
    }

    return payload.datasets;
  } catch {
    return null;
  }
}

function normalizeManifestDatasets(dir, datasets) {
  const options = [];

  for (const entry of datasets) {
    const id = String(entry?.id || "").trim();
    const featureName = String(entry?.feature || "").trim();
    const chipName = String(entry?.chip || "").trim();
    if (!id || !featureName || !chipName) {
      continue;
    }

    options.push({
      id,
      label: String(entry?.label || datasetLabelFromId(id)),
      featureCandidates: [`${dir}${featureName}`],
      chipCandidates: [`${dir}${chipName}`],
    });
  }

  options.sort((a, b) => compareDatasetIds(a.id, b.id));
  return options;
}

async function discoverVersionedDatasets() {
  for (const dir of DATA_DIR_CANDIDATES) {
    const manifest = await fetchDatasetManifest(`${dir}${DATASET_MANIFEST_NAME}`);
    if (!manifest) {
      continue;
    }

    const options = normalizeManifestDatasets(dir, manifest);
    if (options.length) {
      return options;
    }
  }

  const options = [];

  for (const dir of DATA_DIR_CANDIDATES) {
    const listingText = await fetchDirectoryListing(dir);
    if (!listingText) {
      continue;
    }

    const names = new Set(extractHrefTargets(listingText).map(normalizeHrefToName).filter(Boolean));
    const featureSuffixToName = new Map();
    const chipSuffixToName = new Map();

    for (const name of names) {
      const featureMatch = name.match(/^dsa_feature_matrix_(.+)\.csv$/);
      if (featureMatch) {
        featureSuffixToName.set(featureMatch[1], name);
      }

      const chipMatch = name.match(/^dsa_driver_chip_list_(.+)\.csv$/);
      if (chipMatch) {
        chipSuffixToName.set(chipMatch[1], name);
      }
    }

    for (const [suffix, featureName] of featureSuffixToName.entries()) {
      const chipName = chipSuffixToName.get(suffix);
      if (!chipName) {
        continue;
      }

      options.push({
        id: suffix,
        label: datasetLabelFromId(suffix),
        featureCandidates: [`${dir}${featureName}`],
        chipCandidates: [`${dir}${chipName}`],
      });
    }

    if (options.length) {
      break;
    }
  }

  options.sort((a, b) => compareDatasetIds(a.id, b.id));
  return options;
}

function splitCsvLine(line) {
  const cells = [];
  let current = "";
  let inQuotes = false;

  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];

    if (ch === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (ch === "," && !inQuotes) {
      cells.push(current);
      current = "";
      continue;
    }

    current += ch;
  }

  cells.push(current);
  return cells;
}

function parseCsvText(text) {
  const lines = text.replace(/\r/g, "").split("\n");
  const rows = [];

  for (const rawLine of lines) {
    if (rawLine === "") {
      continue;
    }
    rows.push(splitCsvLine(rawLine));
  }

  return rows;
}

function parseMeta(rows) {
  const meta = {
    linuxVersion: "unknown",
    openwrtVersion: "unknown",
    generatedTag: "unknown",
  };

  for (const row of rows) {
    const first = (row[0] || "").trim();
    if (first.startsWith("# Linux:")) {
      meta.linuxVersion = first.slice("# Linux:".length).trim();
    }
    if (first.startsWith("# OpenWrt:")) {
      meta.openwrtVersion = first.slice("# OpenWrt:".length).trim();
    }
    if (first.startsWith("# Generated:")) {
      meta.generatedTag = first.slice("# Generated:".length).trim();
    } else if (first === "# Generated") {
      meta.generatedTag = "yes";
    }
  }

  return meta;
}

function parseFeatureMatrixRows(rows) {
  let header = null;
  const dataRows = [];

  for (const row of rows) {
    const first = (row[0] || "").trim();

    if (!first || first.startsWith("#")) {
      continue;
    }

    if (!header) {
      header = row.map((cell) => cell.trim());
      continue;
    }

    dataRows.push(row);
  }

  if (!header) {
    throw new Error("Feature CSV header not found.");
  }

  const firstColumn = header[0];

  // Transposed shape: driver,feature1,feature2,...
  if (firstColumn === "driver") {
    const features = header.slice(1);
    const records = dataRows
      .map((row) => {
        const driver = (row[0] || "").trim();
        if (!driver) {
          return null;
        }

        const supported = new Set();
        for (let i = 0; i < features.length; i += 1) {
          const cell = (row[i + 1] || "").trim().toLowerCase();
          if (cell === "x") {
            supported.add(features[i]);
          }
        }

        return {
          driver,
          supported,
        };
      })
      .filter(Boolean);

    return { features, records };
  }

  // Non-transposed shape: feature,driver1,driver2,...
  if (firstColumn === "feature") {
    const drivers = header.slice(1).map((name) => name.trim()).filter(Boolean);
    const driverToFeatures = new Map();

    for (const driver of drivers) {
      driverToFeatures.set(driver, new Set());
    }

    for (const row of dataRows) {
      const feature = (row[0] || "").trim();
      if (!feature) {
        continue;
      }

      for (let i = 0; i < drivers.length; i += 1) {
        const cell = (row[i + 1] || "").trim().toLowerCase();
        if (cell === "x") {
          driverToFeatures.get(drivers[i]).add(feature);
        }
      }
    }

    const records = drivers.map((driver) => ({
      driver,
      supported: driverToFeatures.get(driver) || new Set(),
    }));

    const features = dataRows
      .map((row) => (row[0] || "").trim())
      .filter(Boolean);

    return { features, records };
  }

  throw new Error(`Feature CSV header not recognized: expected 'driver' or 'feature', got '${firstColumn}'.`);
}

function parseChipRows(rows) {
  let headerFound = false;
  const chipMap = new Map();

  for (const row of rows) {
    const first = (row[0] || "").trim();

    if (!first || first.startsWith("#")) {
      continue;
    }

    if (!headerFound) {
      if (first !== "driver") {
        throw new Error("Chip CSV header not found or unexpected schema.");
      }
      headerFound = true;
      continue;
    }

    const driver = first;
    const chipsRaw = (row[1] || "").trim();
    const chips = chipsRaw
      ? chipsRaw.split(CHIP_DELIMITER).map((name) => name.trim()).filter(Boolean)
      : [];

    chipMap.set(driver, chips);
  }

  return chipMap;
}

async function fetchCsvFromCandidates(candidates) {
  const errors = [];

  for (const path of candidates) {
    try {
      const response = await fetch(path, { cache: "no-store" });
      if (!response.ok) {
        errors.push(`${path}: HTTP ${response.status}`);
        continue;
      }
      const text = await response.text();
      return { path, text };
    } catch (error) {
      errors.push(`${path}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  throw new Error(`Could not load CSV from any candidate path. ${errors.join(" | ")}`);
}

function setStatus(message, isError = false) {
  const status = document.getElementById("status");
  status.textContent = message;
  status.style.color = isError ? "#8b3d00" : "#4b5a5f";
}

function renderMeta() {
  const meta = document.getElementById("meta");
  meta.textContent = "";

  const linux = document.createElement("span");
  linux.textContent = `Linux: ${state.linuxVersion}`;

  meta.appendChild(linux);

  if (state.openwrtVersion !== "unknown") {
    const openwrt = document.createElement("span");
    openwrt.textContent = `OpenWrt: ${state.openwrtVersion}`;
    meta.appendChild(openwrt);
  }

  if (state.generatedTag !== "unknown") {
    const generated = document.createElement("span");
    generated.textContent = `Generated: ${state.generatedTag}`;
    meta.appendChild(generated);
  }
}

function featureMatchesSearch(feature, searchTerm) {
  if (!searchTerm) {
    return true;
  }
  return feature.toLowerCase().includes(searchTerm.toLowerCase());
}

function getSelectedFeaturesFromUi() {
  const select = document.getElementById("feature-select");
  const values = [];

  for (const option of select.options) {
    if (option.selected) {
      values.push(option.value);
    }
  }

  return values;
}

function renderDatasetSelect() {
  const select = document.getElementById("dataset-select");
  select.textContent = "";

  for (const dataset of state.datasetOptions) {
    const option = document.createElement("option");
    option.value = dataset.id;
    option.textContent = dataset.label;
    option.selected = dataset.id === state.selectedDatasetId;
    select.appendChild(option);
  }
}

function renderFeatureSelect() {
  const select = document.getElementById("feature-select");
  const prevSelected = new Set(state.selectedFeatures);

  select.textContent = "";

  let visibleCount = 0;
  for (const feature of state.features) {
    if (!featureMatchesSearch(feature, state.searchTerm)) {
      continue;
    }

    const option = document.createElement("option");
    option.value = feature;
    option.textContent = feature;
    option.selected = prevSelected.has(feature);
    select.appendChild(option);
    visibleCount += 1;
  }

  setStatus(`Feature list: ${visibleCount} shown, ${state.features.length} total.`);
}

function recordMatchesSelectedFeatures(record, selectedFeatures) {
  for (const feature of selectedFeatures) {
    if (!record.supported.has(feature)) {
      return false;
    }
  }
  return true;
}

function updateUrlQuery() {
  const params = new URLSearchParams(window.location.search);
  const features = Array.from(state.selectedFeatures).sort();

  if (state.selectedDatasetId) {
    params.set("dataset", state.selectedDatasetId);
  } else {
    params.delete("dataset");
  }

  if (features.length) {
    params.set("features", features.join(","));
  } else {
    params.delete("features");
  }

  const search = state.searchTerm.trim();
  if (search) {
    params.set("q", search);
  } else {
    params.delete("q");
  }

  const newUrl = `${window.location.pathname}${params.toString() ? `?${params}` : ""}`;
  window.history.replaceState({}, "", newUrl);
}

function applyQueryToState() {
  const params = new URLSearchParams(window.location.search);
  const dataset = (params.get("dataset") || "").trim();
  const featureParam = (params.get("features") || "").trim();
  const query = (params.get("q") || "").trim();

  state.selectedDatasetId = dataset;

  state.selectedFeatures.clear();
  if (featureParam) {
    for (const feature of featureParam.split(",")) {
      const trimmed = feature.trim();
      if (trimmed) {
        state.selectedFeatures.add(trimmed);
      }
    }
  }

  state.searchTerm = query;
}

function renderTable() {
  const selectedFeatures = Array.from(state.selectedFeatures);
  const shownFeatures = selectedFeatures.length ? selectedFeatures : state.features;
  const visibleRecords = state.records.filter((record) => recordMatchesSelectedFeatures(record, selectedFeatures));

  const head = document.getElementById("matrix-head");
  const body = document.getElementById("matrix-body");
  const stats = document.getElementById("stats");

  head.textContent = "";
  body.textContent = "";

  const headerRow = document.createElement("tr");

  const thDriver = document.createElement("th");
  thDriver.textContent = "driver";
  headerRow.appendChild(thDriver);

  const thChips = document.createElement("th");
  thChips.textContent = "chips";
  headerRow.appendChild(thChips);

  for (const feature of shownFeatures) {
    const th = document.createElement("th");
    th.textContent = feature;
    headerRow.appendChild(th);
  }

  head.appendChild(headerRow);

  const chipTemplate = document.getElementById("chip-template");

  for (const record of visibleRecords) {
    const tr = document.createElement("tr");

    const driverCell = document.createElement("th");
    driverCell.scope = "row";
    driverCell.textContent = record.driver;
    tr.appendChild(driverCell);

    const chipsCell = document.createElement("td");
    chipsCell.className = "chips-cell";

    if (!record.chips.length) {
      const empty = document.createElement("span");
      empty.className = "missing-chip";
      empty.textContent = "-";
      chipsCell.appendChild(empty);
    } else {
      const wrap = document.createElement("div");
      wrap.className = "chips";
      for (const chipName of record.chips) {
        const node = chipTemplate.content.firstElementChild.cloneNode(true);
        node.textContent = chipName;
        wrap.appendChild(node);
      }
      chipsCell.appendChild(wrap);
    }
    tr.appendChild(chipsCell);

    for (const feature of shownFeatures) {
      const td = document.createElement("td");
      td.className = "feature-cell";
      if (record.supported.has(feature)) {
        td.classList.add("supported");
        td.textContent = "x";
      }
      tr.appendChild(td);
    }

    body.appendChild(tr);
  }

  stats.textContent = [
    `Drivers shown: ${visibleRecords.length}/${state.records.length}`,
    `Columns shown: ${shownFeatures.length}/${state.features.length}`,
    `Selected filters: ${selectedFeatures.length}`,
  ].join(" | ");

  if (!visibleRecords.length) {
    setStatus("No drivers match the selected feature filters.", true);
  }
}

function syncUiFromState() {
  const searchInput = document.getElementById("feature-search");
  searchInput.value = state.searchTerm;
  renderFeatureSelect();

  const select = document.getElementById("feature-select");
  for (const option of select.options) {
    option.selected = state.selectedFeatures.has(option.value);
  }
}

function registerEvents() {
  const datasetSelect = document.getElementById("dataset-select");
  const searchInput = document.getElementById("feature-search");
  const featureSelect = document.getElementById("feature-select");
  const clearButton = document.getElementById("clear-filters");

  datasetSelect.addEventListener("change", async () => {
    state.selectedDatasetId = datasetSelect.value;
    updateUrlQuery();
    try {
      await loadSelectedDataset();
      renderMeta();
      syncUiFromState();
      renderTable();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setStatus(message, true);
    }
  });

  searchInput.addEventListener("input", () => {
    state.searchTerm = searchInput.value;
    renderFeatureSelect();
    updateUrlQuery();
  });

  featureSelect.addEventListener("change", () => {
    state.selectedFeatures = new Set(getSelectedFeaturesFromUi());
    updateUrlQuery();
    renderTable();
  });

  clearButton.addEventListener("click", () => {
    state.selectedFeatures.clear();
    state.searchTerm = "";
    syncUiFromState();
    updateUrlQuery();
    renderTable();
  });
}

function mergeRecords(featureRecords, chipMap) {
  const merged = [];
  for (const record of featureRecords) {
    merged.push({
      driver: record.driver,
      supported: record.supported,
      chips: chipMap.get(record.driver) || [],
    });
  }
  return merged;
}

async function loadSelectedDataset() {
  const selected = state.datasetOptions.find((item) => item.id === state.selectedDatasetId) || state.datasetOptions[0];
  if (!selected) {
    throw new Error("No dataset options available.");
  }

  state.selectedDatasetId = selected.id;
  renderDatasetSelect();

  const featureCandidates = selected.featureCandidates;
  const chipCandidates = selected.chipCandidates;

  setStatus(`Loading dataset: ${selected.label}...`);

  const [{ path: featurePath, text: featureText }, { path: chipPath, text: chipText }] = await Promise.all([
    fetchCsvFromCandidates(featureCandidates),
    fetchCsvFromCandidates(chipCandidates),
  ]);

  const featureRows = parseCsvText(featureText);
  const chipRows = parseCsvText(chipText);

  const featureMeta = parseMeta(featureRows);
  const chipMeta = parseMeta(chipRows);

  state.linuxVersion = featureMeta.linuxVersion !== "unknown"
    ? featureMeta.linuxVersion
    : chipMeta.linuxVersion;
  state.openwrtVersion = featureMeta.openwrtVersion !== "unknown"
    ? featureMeta.openwrtVersion
    : chipMeta.openwrtVersion;
  state.generatedTag = featureMeta.generatedTag !== "unknown"
    ? featureMeta.generatedTag
    : chipMeta.generatedTag;

  const parsedFeature = parseFeatureMatrixRows(featureRows);
  const chipMap = parseChipRows(chipRows);

  state.features = parsedFeature.features;
  state.records = mergeRecords(parsedFeature.records, chipMap);
  state.selectedFeatures = new Set(
    Array.from(state.selectedFeatures).filter((feature) => state.features.includes(feature)),
  );

  setStatus(`Loaded ${state.records.length} drivers from ${featurePath} and chips from ${chipPath}.`);
}

async function boot() {
  applyQueryToState();
  const requestedDataset = (new URLSearchParams(window.location.search).get("dataset") || "").trim();

  const discovered = await discoverVersionedDatasets();
  state.datasetOptions = discovered;

  if (!state.datasetOptions.length) {
    throw new Error("No versioned dataset pairs found under data/. Generate the CSV files and data/datasets.json first.");
  }

  if (!requestedDataset && discovered.length) {
    state.selectedDatasetId = discovered[0].id;
  }

  if (!state.datasetOptions.some((item) => item.id === state.selectedDatasetId)) {
    state.selectedDatasetId = state.datasetOptions[0].id;
  }

  renderDatasetSelect();
  await loadSelectedDataset();

  renderMeta();
  syncUiFromState();
  renderTable();
}

window.addEventListener("DOMContentLoaded", async () => {
  registerEvents();
  try {
    await boot();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    setStatus(message, true);
  }
});
