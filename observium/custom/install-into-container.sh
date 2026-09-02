#!/bin/bash
# Apply home-ops overlays inside the Observium container.
# Idempotent: safe on every container start (live restart and Pi rebuild).
set -e

MARKER="HOMEOPS_WD_CENTIGRADE"
DISCOVERY_FILE="/opt/observium/includes/discovery/sensors/mycloudex2ultra-mib.inc.php"

log() { echo "home-ops: $*"; }

# --- Teach snmp_fix_numeric() to parse WD "Centigrade:N" DisplayStrings ---
patch_snmp_fix_numeric() {
    local target=""
    local f
    for f in \
        /opt/observium/includes/snmp.inc.php \
        /opt/observium/includes/functions.inc.php \
        /opt/observium/includes/common.inc.php \
        /opt/observium/includes/rewrites.inc.php
    do
        if [ -f "$f" ] && grep -q 'function snmp_fix_numeric' "$f"; then
            target="$f"
            break
        fi
    done

    if [ -z "$target" ]; then
        log "WARN: snmp_fix_numeric() not found; WD string temps may not graph"
        return 0
    fi

    if grep -q "$MARKER" "$target"; then
        log "snmp_fix_numeric already patched in $target"
        return 0
    fi

    python3 - "$target" "$MARKER" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text()
needle = "function snmp_fix_numeric"
idx = text.find(needle)
if idx < 0:
    raise SystemExit(0)
brace = text.find("{", idx)
if brace < 0:
    raise SystemExit("no opening brace for snmp_fix_numeric")
insert = f"""
  // {marker}: WD My Cloud EX2 Ultra reports temps as DisplayString
  if (is_string($value) && preg_match('/Centigrade:\\s*(-?\\d+(?:\\.\\d+)?)/i', $value, $homeops_m)) {{
    return $homeops_m[1] + 0;
  }}
"""
path.write_text(text[: brace + 1] + insert + text[brace + 1 :])
print(f"patched snmp_fix_numeric in {path}")
PY
}

# --- Ensure discovery loads the WD module even if this Observium build
#     only includes sensor files listed on the OS MIB list. ---
patch_sensors_discovery() {
    local target="/opt/observium/includes/discovery/sensors.inc.php"
    if [ ! -f "$target" ]; then
        log "WARN: $target not found"
        return 0
    fi
    if grep -q "HOMEOPS_MYCLOUDEX2ULTRA" "$target"; then
        log "sensors.inc.php already includes WD module"
        return 0
    fi
    if [ ! -f "$DISCOVERY_FILE" ]; then
        log "WARN: $DISCOVERY_FILE not mounted"
        return 0
    fi

    python3 - "$target" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
snippet = """
// HOMEOPS_MYCLOUDEX2ULTRA
$homeops_wd_mod = (isset($config['install_dir']) ? $config['install_dir'] : '/opt/observium') . '/includes/discovery/sensors/mycloudex2ultra-mib.inc.php';
if (isset($device) && is_file($homeops_wd_mod)) {
  include_once($homeops_wd_mod);
}
unset($homeops_wd_mod);
"""
stripped = text.rstrip()
if stripped.endswith("?>"):
    text = stripped[:-2].rstrip() + "\n" + snippet
else:
    text = text.rstrip() + "\n" + snippet
path.write_text(text + "\n")
print(f"patched {path}")
PY
}

patch_snmp_fix_numeric
patch_sensors_discovery
log "WD My Cloud overlay ready"
