#!/bin/sh
# tested-on-main_test.sh: fixtures for tested-on-main.sh's decision.
#
# For each case, recorded API responses are written to a temporary fixtures
# directory and the script is run against it. The cases cover the decisions a
# main run may face: a green CI result on the exact commit (skip), a green CI
# result on a pull request head whose tree equals the commit (skip), a pull
# request merged red or without a run, and no pull request at all (run
# everything). Exits nonzero if any case fails.
set -u

HERE="$(cd "$(dirname -- "$0")" && pwd)"
SCRIPT="${HERE}/tested-on-main.sh"
FAILURES=0
TOTAL=0

new_fixtures() {
	FIX="$(mktemp -d)"
	echo '{"check_runs":[]}' > "${FIX}/check-runs--never.json"
	printf '{"tree":{"sha":"tree111"}}' > "${FIX}/commits--never.json"
	echo '[]' > "${FIX}/pulls--never.json"
}

write_check_runs() { # $1 = dir, $2 = sha, $3 = conclusion (or empty for no CI result at all)
	if [ -z "${3}" ]; then
		printf '{"check_runs":[{"name":"Test · Linux x64","conclusion":"success"}]}' > "${1}/check-runs--${2}.json"
	else
		printf '{"check_runs":[{"name":"CI result","conclusion":"%s"}]}' "${3}" > "${1}/check-runs--${2}.json"
	fi
}

write_no_check_runs() { # $1 = dir, $2 = sha: the API returns no CI result at all
	printf '{"check_runs":[]}' > "${1}/check-runs--${2}.json"
}

write_commit() { # $1 = dir, $2 = sha, $3 = tree sha
	printf '{"tree":{"sha":"%s"}}' "${3}" > "${1}/commits--${2}.json"
}

write_pulls() { # $1 = dir, $2 = sha, rest = head shas
	dir="$1"
	sha="$2"
	shift 2
	body=""
	for head in "$@"; do
		body="${body}{\"head\":{\"sha\":\"${head}\"}},"
	done
	printf '[%s]' "${body%,}" > "${dir}/pulls--${sha}.json"
}

run_case() { # $1 = name, $2 = expected tested value, rest = script args
	name="$1"
	expected="$2"
	shift 2
	TOTAL=$((TOTAL + 1))
	out="$("${SCRIPT}" "$@" 2>&1)"
	got="$(echo "${out}" | sed -n 's/^tested=//p')"
	if [ "${got}" = "${expected}" ]; then
		echo "ok   ${name}"
	else
		FAILURES=$((FAILURES + 1))
		echo "FAIL ${name}: expected tested=${expected}, got tested=${got}"
		echo "${out}" | sed 's/^/     /'
	fi
	rm -rf "${FIX}"
}

# Case 1: a green CI result on the exact commit.
new_fixtures
write_commit "${FIX}" main111 tree111
write_check_runs "${FIX}" main111 success
write_pulls "${FIX}" main111
run_case "green CI result on the exact commit skips" true main111 branch "" "${FIX}"

# Case 2: no CI result on the commit; the pull request head's tree equals it, and it was green.
new_fixtures
write_commit "${FIX}" main222 tree222
write_check_runs "${FIX}" main222 "" ""
write_commit "${FIX}" pr333 tree222
write_check_runs "${FIX}" pr333 success
write_pulls "${FIX}" main222 pr333
run_case "green CI result on a same-tree pull request head skips" true main222 branch "" "${FIX}"

# Case 3: the pull request was merged red.
new_fixtures
write_commit "${FIX}" main333 tree333
write_commit "${FIX}" pr444 tree333
write_check_runs "${FIX}" pr444 failure
write_pulls "${FIX}" main333 pr444
run_case "a pull request merged red runs everything" false main333 branch "" "${FIX}"

# Case 4: the pull request has no check runs at all.
new_fixtures
write_commit "${FIX}" main444 tree444
write_commit "${FIX}" pr555 tree444
write_no_check_runs "${FIX}" pr555
write_pulls "${FIX}" main444 pr555
run_case "a pull request without a run runs everything" false main444 branch "" "${FIX}"

# Case 5: the pull request's tree differs (the commit is not what was reviewed).
new_fixtures
write_commit "${FIX}" main555 tree565
write_commit "${FIX}" pr666 tree666
write_check_runs "${FIX}" pr666 success
write_pulls "${FIX}" main555 pr666
run_case "a different-tree pull request runs everything" false main555 branch "" "${FIX}"

# Case 6: nothing associated with the commit.
new_fixtures
write_commit "${FIX}" main666 tree777
write_pulls "${FIX}" main666
run_case "no pull request runs everything" false main666 branch "" "${FIX}"

# Case 7: a pull request run itself always runs everything.
new_fixtures
write_commit "${FIX}" main777 tree888
write_check_runs "${FIX}" main777 success
write_pulls "${FIX}" main777
run_case "a pull request run runs everything" false main777 pull_request 42 "${FIX}"

# Case 8: a tag on a commit whose CI result is green.
new_fixtures
write_commit "${FIX}" tag123 tree999
write_check_runs "${FIX}" tag123 success
write_pulls "${FIX}" tag123
run_case "a tag on a tested commit skips" true tag123 tag "" "${FIX}"

# Case 9: a tag on a commit whose pull request was red.
new_fixtures
write_commit "${FIX}" tag321 tree999
write_commit "${FIX}" pr777 tree999
write_check_runs "${FIX}" pr777 failure
write_pulls "${FIX}" tag321 pr777
run_case "a tag whose pull request was red runs everything" false tag321 tag "" "${FIX}"

# Case 10: CI result checks exist on the commit, but none succeeded.
new_fixtures
write_commit "${FIX}" main888 tree111
write_check_runs "${FIX}" main888 failure
write_pulls "${FIX}" main888
run_case "a red CI result on the exact commit runs everything" false main888 branch "" "${FIX}"

echo "${TOTAL} cases, $((TOTAL - FAILURES)) passed"
[ "${FAILURES}" -eq 0 ]
