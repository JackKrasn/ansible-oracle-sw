#!/usr/bin/env bash
# Author: Leonid Babkin

declare _FAILED=()

_PIPE=$(mktemp -u)
mkfifo $_PIPE
exec 7<>$_PIPE
_run_jobs() {
    local SCREEN_JOB_ID=1
    local ARGS=("$@")
    local JOBCOUNT=${#ARGS[@]}
    for arg in "${ARGS[@]}"; do
	echo "state=running jobid=$SCREEN_JOB_ID jobcount=$JOBCOUNT command=$arg"
	screen -d -m bash -c "exec 7<>$_PIPE; trap 'RC="'$?'"; echo completed $SCREEN_JOB_ID $JOBCOUNT "'$RC'" "'"'"$arg"'"'" >&7;trap - EXIT; exit "'$RC'"' ERR EXIT; $arg"
	((SCREEN_JOB_ID++))
    done
}

_wait_jobs() {
    echo "Wait for background jobs"
    local jobiter=0 state jobid jobcount exitcode jobcmd status_string
        
    while read -r -u 7 state jobid jobcount exitcode jobcmd; do
	((jobiter++))
	#echo -n "$(printf '=%.0s' {1..20}) JOBCMD: $jobcmd $(printf '=%.0s' {1..130})" | sed 's/^\(.\{150\}\).*/\1/'; echo
	printf '=%.0s' {1..150}; echo
	status_string="state=$state jobid=$jobid jobcount=$jobcount exitcode=$exitcode command=$jobcmd"
	echo "$status_string"
	((exitcode != 0)) && _FAILED+=("$status_string")
	((jobiter == jobcount)) && break
    done
}

run_job_pool() {
    local _JOBS=("$@")
    trap "rm -f $_PIPE" ERR EXIT
    _run_jobs "${_JOBS[@]}"
    _wait_jobs
    printf '\n%s\n' failed:
    printf '%s\n' "${_FAILED[@]}"
}
