const FEATURE_CSV_CANDIDATES = [
  "../dsa_feature_matrix.csv",
  "./data/dsa_feature_matrix.csv",
];

const CHIP_CSV_CANDIDATES = [
  "../dsa_driver_chip_list.csv",
  "./data/dsa_driver_chip_list.csv",
];

const CHIP_DELIMITER = "; ";

const state = {
  linuxVersion: "unknown",
  openwrtVersion: "unknown",
  features: [],
  records: [],
  searchTerm: "",
  selectedFeatures: new Set(),
};

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
  };

  for (const row of rows) {
    const first = (row[0] || "").trim();
    if (first.startsWith("# Linux:")) {
      meta.linuxVersion = first.slice("# Linux:".length).trim();
    }
    if (first.startsWith("# OpenWrt:")) {
      meta.openwrtVersion = first.slice("# OpenWrt:".length).trim();
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

  if (!header || header[0] !== "driver") {
    throw new Error("Feature CSV header not found or unexpected schema.");
  }

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

  const openwrt = document.createElement("span");
  openwrt.textContent = `OpenWrt: ${state.openwrtVersion}`;

  meta.appendChild(linux);
  meta.appendChild(openwrt);
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
  const featureParam = (params.get("features") || "").trim();
  const query = (params.get("q") || "").trim();

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
  const searchInput = document.getElementById("feature-search");
  const featureSelect = document.getElementById("feature-select");
  const clearButton = document.getElementById("clear-filters");

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

async function boot() {
  setStatus("Loading CSV files...");

  const [{ path: featurePath, text: featureText }, { path: chipPath, text: chipText }] = await Promise.all([
    fetchCsvFromCandidates(FEATURE_CSV_CANDIDATES),
    fetchCsvFromCandidates(CHIP_CSV_CANDIDATES),
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

  const parsedFeature = parseFeatureMatrixRows(featureRows);
  const chipMap = parseChipRows(chipRows);

  state.features = parsedFeature.features;
  state.records = mergeRecords(parsedFeature.records, chipMap);

  applyQueryToState();
  state.selectedFeatures = new Set(
    Array.from(state.selectedFeatures).filter((feature) => state.features.includes(feature)),
  );

  renderMeta();
  syncUiFromState();
  renderTable();

  setStatus(`Loaded ${state.records.length} drivers from ${featurePath} and chips from ${chipPath}.`);
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
