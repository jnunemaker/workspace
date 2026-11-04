#!/bin/sh
# Verify the port cleanup run/archive already own. Allocation is not proof of
# process ownership; never escalate signals or chase replacement processes.

# ── Socket inspection ──────────────────────────────────────────

# Read one snapshot within the caller's deadline. Use field output so process
# names, IPv6 addresses and missing login names do not shift table columns.
workspace_port_snapshot() {
  lsof -nP -i ":$1-$(( $1 + 9 ))" -FpcuLPnT > "$3/raw" 2> "$3/error" &
  # Poll only our inspection child here. A stalled lsof must not consume an
  # unlimited shutdown wait, and its PID must never enter the app signal list.
  _port_probe=$!
  while command kill -0 "$_port_probe" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$2" ]; then
      command kill -TERM "$_port_probe" 2>/dev/null || true
      err "Port inspection timed out; could not verify cleanup."
      return 1
    fi
    sleep 0.1
  done
  _port_status=0
  wait "$_port_probe" || _port_status=$?
  # lsof uses status 1 for no matches as well as errors. Only an empty,
  # diagnostic-free result may mean clear; partial or failed inspection cannot.
  _port_inspection_failed=0
  if [ -s "$3/error" ] || [ "$_port_status" -gt 1 ] ||
    { [ "$_port_status" -eq 1 ] && [ -s "$3/raw" ]; }; then
    err "lsof could not reliably inspect ports; check that it is installed and permitted to inspect processes."
    _port_inspection_failed=1
  fi
  awk -v base="$1" '
    function clean(value) { gsub(/[[:cntrl:]]/, "?", value); return value }
    function emit(    endpoint, port) {
      if (!file) return
      if (pid !~ /^[0-9]+$/ || pid <= 1 || name == "" || protocol == "") { bad=1; return }
      if (protocol != "TCP" && protocol != "UDP") { bad=1; return }
      # lsof port filters match either endpoint. Select local bindings only;
      # a client connected to this workspace must not be killed with its server.
      endpoint=name; sub(/->.*/, "", endpoint)
      port=endpoint; sub(/^.*:/, "", port)
      if (port !~ /^[0-9]+$/) { bad=1; return }
      if (port+0 < base+0 || port+0 > base+9) return
      if (protocol == "TCP" && state == "") { bad=1; return }
      if (protocol == "TCP" && state != "LISTEN") return
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        pid, port, protocol, clean(endpoint),
        (state ? clean(state) : "BOUND"),
        (command ? clean(command) : "?"), (user ? clean(user) : "?")
    }
    /^p/ { emit(); file=0; pid=substr($0,2); command=""; user=""; next }
    /^c/ { command=substr($0,2); next }
    /^u/ { if (!user) user=substr($0,2); next }
    /^L/ { user=substr($0,2); next }
    /^f/ { emit(); files++; file=1; name=""; protocol=""; state=""; next }
    /^P/ { protocol=substr($0,2); next }
    /^n/ { name=substr($0,2); next }
    /^TST=/ { state=substr($0,5); next }
    /^T/ { next }
    { bad=1 }
    END { emit(); if (bad || (NR && !files)) exit 1 }
  ' "$3/raw" || _port_inspection_failed=1
  # Keep safely parsed rows for diagnostics even when other results are
  # incomplete. Failure prevents the caller from using them for termination.
  [ "$_port_inspection_failed" -eq 0 ]
}

report_workspace_ports() {
  [ -s "$1" ] || return 0
  printf '  PID\tPORT\tPROTOCOL\tLOCAL ADDRESS\tSTATE\tPROCESS\tUSER\n' >&2
  cat "$1" >&2
}

# ── Stop once, then verify ──────────────────────────────────────

# A subshell contains scratch variables and the temporary-file cleanup trap;
# run/archive retain their own lifecycle state and registry-lock traps.
clear_workspace_ports() (
  _port_base=$(validate_workspace_port_block "$1") || exit 1
  _port_tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$_port_tmp"' EXIT
  _port_deadline=$(( $(date +%s) + 5 ))
  if ! workspace_port_snapshot "$_port_base" "$_port_deadline" "$_port_tmp" > "$_port_tmp/remaining"; then
    err "Port cleanup stopped before application termination; no reliable socket snapshot."
    report_workspace_ports "$_port_tmp/remaining"
    exit 1
  fi
  [ -s "$_port_tmp/remaining" ] || exit 0

  # If inspection consumed the budget, do not stop an application without
  # leaving time to observe release. Report the known occupants instead.
  if [ "$(date +%s)" -ge "$_port_deadline" ]; then
    err "Port inspection exhausted the cleanup budget; no application signals sent."
    report_workspace_ports "$_port_tmp/remaining"
    exit 1
  fi

  # Deduplicate processes listening on multiple ports. Ignore an exit race;
  # the following snapshots determine whether the required ports were released.
  for _port_pid in $(cut -f1 "$_port_tmp/remaining" | sort -u); do
    kill -TERM "$_port_pid" 2>/dev/null || true
  done
  # Refresh the observed sockets without signaling again. A new occupant is
  # a conflict to report, not permission to terminate another process.
  while [ "$(date +%s)" -lt "$_port_deadline" ]; do
    if ! workspace_port_snapshot "$_port_base" "$_port_deadline" "$_port_tmp" > "$_port_tmp/next"; then
      err "Cleanup could not be verified. Last observed sockets:"
      break
    fi
    mv "$_port_tmp/next" "$_port_tmp/remaining"
    [ -s "$_port_tmp/remaining" ] || exit 0
    sleep 0.1
  done
  err "Ports remain occupied or could not be verified clear; cleanup stopped."
  report_workspace_ports "$_port_tmp/remaining"
  err "Check these processes in their owning app or terminal, then retry. Port use does not prove checkout ownership."
  exit 1
)
