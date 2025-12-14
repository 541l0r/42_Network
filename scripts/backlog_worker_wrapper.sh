#!/bin/bash

# Wrapper to load token and start worker

ROOT_DIR="/srv/42_Network/repo"
cd "$ROOT_DIR"

# Load token
source .oauth_state

# Export for child process
export API_TOKEN="$ACCESS_TOKEN"

# Run worker
exec bash scripts/backlog_worker.sh
