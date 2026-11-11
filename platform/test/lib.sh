# Shared by e2e.sh and e2e-workflow.sh. Source it after setting REPORT_TITLE.
# Each script keeps its own RESULTS, so a suite run from e2e.sh reports separately.

RESULTS=()
FAILURES=0
RUN_START=$(date +%s)

record() { # phase check status detail
  RESULTS+=("$1|$2|$3|$4")
  [[ "$3" == FAIL* ]] && FAILURES=$((FAILURES + 1))
  printf '  [%s] %s - %s%s\n' "$3" "$2" "$1" "${4:+ ($4)}"
}

report() {
  echo
  echo "============================ ${REPORT_TITLE} ============================"
  printf '%s\n' "PHASE|CHECK|RESULT|DETAIL" "${RESULTS[@]}" | column -t -s'|'
  echo "====================================================================="
  if (( FAILURES > 0 )); then
    echo "VERDICT: FAIL ($FAILURES check(s) failed)"
  else
    echo "VERDICT: PASS"
  fi
  echo "Total time: $(( ($(date +%s) - RUN_START) / 60 ))m $(( ($(date +%s) - RUN_START) % 60 ))s"
}

wait_until() { # timeout_seconds command... -> 0 once the command exits 0
  local timeout=$1 start
  shift
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) - start > timeout )) && return 1
    sleep 5
  done
}
