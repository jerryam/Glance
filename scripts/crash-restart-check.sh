#!/bin/zsh
# Runs the built Glance.app on this Mac, crashes it on purpose and checks what happens next. It needs no
# permissions, and quits every copy of 一瞥 running under this user, so it is for CI or a Mac not in use.
set -u
cd "$(dirname "$0")/.."
app="$PWD/Glance.app"
binary="$app/Contents/MacOS/Glance"
domain=com.jethro.windowhop
key=WindowHop.crashRestarts.v1

current() { pgrep -x Glance | tail -1 }
finish() {
    pkill -x Glance 2>/dev/null
    defaults delete "$domain" "$key" 2>/dev/null
    return 0
}
fail() {
    print "::error::$1"
    print "--- crash reports"
    ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i glance | head -5
    finish
    exit 1
}
# Prints the pid of a copy other than $1, once there is one within $2 seconds.
wait_for_other() {
    local other=$1 tries=$(( $2 * 2 )) found
    while (( tries-- > 0 )); do
        found=$(current)
        if [[ -n "$found" && "$found" != "$other" ]]; then print -- "$found"; return 0; fi
        sleep 0.5
    done
    return 1
}
diagnostics() { "$binary" --diagnostics 2>&1 | tr -d ' \n' }

pkill -x Glance 2>/dev/null
sleep 1
defaults delete "$domain" "$key" 2>/dev/null

print "1. It starts, and is ready to reopen."
open -n "$app" || fail "open could not start the app"
first=$(wait_for_other "" 20) || fail "the app did not start, or crashed while starting"
sleep 4
[[ "$(current)" == "$first" ]] || fail "the app did not stay running"
report=$(diagnostics)
print -- "${report[1,300]}"
[[ "$report" == *'"armed":true'* ]] || fail "not armed: $report"

print "2. A crash reopens it."
kill -SEGV "$first"
second=$(wait_for_other "$first" 15) || fail "no new copy after a crash"
sleep 4
report=$(diagnostics)
[[ "$report" == *'"recent":1'* ]] || fail "the reopening was not recorded: $report"

print "3. Being asked to quit does not."
kill -TERM "$second"
sleep 7
[[ -z "$(current)" ]] && print "   stayed closed" || fail "reopened after SIGTERM"

print "4. A run of crashes stops."
open -n "$app" || fail "open could not start the app"
third=$(wait_for_other "" 20) || fail "the app did not start a second time"
sleep 4
kill -ABRT "$third"
fourth=$(wait_for_other "$third" 15) || fail "no new copy after the second crash"
sleep 4
kill -SEGV "$fourth"
fifth=$(wait_for_other "$fourth" 15) || fail "no new copy after the third crash"
sleep 4
kill -SEGV "$fifth"
sleep 8
[[ -z "$(current)" ]] && print "   stayed closed" || fail "still reopening after three times in a row"

finish
print "Crash restart: all checks passed"
