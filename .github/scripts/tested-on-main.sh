#!/bin/sh
# tested-on-main.sh: may this run skip its build and test jobs?
#
# A commit is "tested" only when a `CI result` check succeeded on the exact
# commit, or on a pull request head whose tree equals the commit's tree (a
# pull request that was rebased or squash-merged carries its tree onto main).
# Otherwise the run builds and tests everything. Every decision is printed
# with its reason, so the run's log says why.
#
# Usage: tested-on-main.sh <sha> <ref_type> <pr-number-or-empty> [fixtures]
#   ref_type   branch | tag | pull_request (passes straight through; pull
#              requests always run everything)
#   fixtures   a directory with recorded API responses, used by the test
#              instead of calling the API. Files are named
#              <kind>--<sha>.json: check-runs--<sha>.json is what
#              `GET /commits/<sha>/check-runs` returns, pulls--<sha>.json what
#              `GET /commits/<sha>/pulls` returns, and commits--<sha>.json what
#              `GET /commits/<sha>` returns. A missing file is treated as an
#              empty response.
# Prints a line `reason: ...` then `tested=true|false`.
set -eu

SHA="${1:-}"
REF_TYPE="${2:-}"
PR="${3:-}"
FIXTURES="${4:-}"

if [ -z "${SHA}" ]; then
	echo "tested-on-main: no sha given" >&2
	exit 2
fi

if [ -n "${FIXTURES}" ]; then
	WORK="${FIXTURES}"
else
	WORK="$(mktemp -d)"
	trap 'rm -rf "${WORK}"' EXIT HUP INT TERM
	gh api "repos/${GITHUB_REPOSITORY}/commits/${SHA}/check-runs?check_name=CI%20result&per_page=10" > "${WORK}/check-runs--${SHA}.json"
	gh api "repos/${GITHUB_REPOSITORY}/commits/${SHA}" > "${WORK}/commits--${SHA}.json"
	gh api "repos/${GITHUB_REPOSITORY}/commits/${SHA}/pulls?per_page=10" > "${WORK}/pulls--${SHA}.json" \
		|| echo "[]" > "${WORK}/pulls--${SHA}.json"
	for head in $(jq -r '.[].head.sha' "${WORK}/pulls--${SHA}.json"); do
		gh api "repos/${GITHUB_REPOSITORY}/commits/${head}" > "${WORK}/commits--${head}.json"
		gh api "repos/${GITHUB_REPOSITORY}/commits/${head}/check-runs?check_name=CI%20result&per_page=10" > "${WORK}/check-runs--${head}.json"
	done
fi

ci_result_success() { # $1 = a check-runs--*.json file
	[ -f "$1" ] || return 1
	count="$(jq -r '[.check_runs[]? | select(.name == "CI result") | select(.conclusion == "success")] | length' "$1" 2>/dev/null || echo 0)"
	[ "${count}" != "0" ]
}

say() { # $1 = tested value, rest = reason
	tested="$1"
	shift
	echo "reason: $*"
	echo "tested=${tested}"
	exit 0
}

if [ -n "${PR}" ]; then
	say false "pull requests run everything"
fi

if ci_result_success "${WORK}/check-runs--${SHA}.json"; then
	say true "a CI result check succeeded on ${SHA}"
fi

associated="$(jq -r 'length' "${WORK}/pulls--${SHA}.json" 2>/dev/null || echo 0)"
if [ "${associated}" = "0" ]; then
	say false "no CI result check on ${SHA} and no pull request associated with it: run everything"
fi

for head in $(jq -r '.[].head.sha' "${WORK}/pulls--${SHA}.json"); do
	tree_sha="$(jq -r '.tree.sha // empty' "${WORK}/commits--${SHA}.json" 2>/dev/null)"
	tree_head="$(jq -r '.tree.sha // empty' "${WORK}/commits--${head}.json" 2>/dev/null)"
	if [ -n "${tree_sha}" ] && [ "${tree_sha}" = "${tree_head}" ]; then
		if ci_result_success "${WORK}/check-runs--${head}.json"; then
			say true "a CI result check succeeded on pull request head ${head}, whose tree equals ${SHA}"
		else
			say false "pull request head ${head} merged without a green CI result: run everything"
		fi
	fi
done

say false "the associated pull request has a different tree, or no green CI result: run everything"
