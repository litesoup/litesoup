# Loaded by every .bats file via `load test_helper`.
# Resolves the repo root and loads bats-support + bats-assert.
TEST_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_HELPER_DIR}/../.." && pwd)"
export REPO_ROOT

load "${TEST_HELPER_DIR}/bats-support/load"
load "${TEST_HELPER_DIR}/bats-assert/load"
