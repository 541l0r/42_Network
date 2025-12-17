#!/bin/bash

# Wrapper to load token and start worker

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# Load token
source .oauth_state

# Export for child process
export API_TOKEN="$ACCESS_TOKEN"

# Run worker
exec bash scripts/agents/backlog_worker.sh
