#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o pipefail

echo "Starting Schema Test Runner Script..."

SOCKET_PATH="/tmp/wsd-test.sock"
AGENT_LOG="/tmp/wsd-schema-test.log"

if [ -n "$KPS_IP" ]; then
    echo "Running in VM_PROTECTION mode."
    echo "Waiting for KPS gRPC port at $KPS_IP:50050 to accept TCP..."
    if ! timeout 120s bash -c "until (echo > /dev/tcp/$KPS_IP/50050) 2>/dev/null; do sleep 2; done"; then
        echo "ERROR: KPS at $KPS_IP:50050 did not become reachable within 120s."
        exit 1
    fi

    echo "Starting WSD Agent (KEY_PROTECTION_VM) in background..."
    KEY_PROTECTION_MECHANISM=KEY_PROTECTION_VM \
    SERVICE_ROLE=SERVICE_ROLE_WSD \
    KPS_IP="$KPS_IP" \
        /app/agent --socket "$SOCKET_PATH" --kps-vm-ip "$KPS_IP" >"$AGENT_LOG" 2>&1 &
    AGENT_PID=$!
else
    echo "Running in EMULATED mode."
    echo "Starting WSD Agent in background..."
    /app/agent --socket "$SOCKET_PATH" >"$AGENT_LOG" 2>&1 &
    AGENT_PID=$!
fi

echo "Waiting for socket to be ready..."
timeout 30s bash -c "until [ -S '$SOCKET_PATH' ]; do sleep 1; done"
if [ $? -ne 0 ]; then
    echo "ERROR: WSD Agent socket was not created in time."
    kill -9 $AGENT_PID || true
    cat "$AGENT_LOG" || true
    exit 1
fi

echo "Running WSD API Signature Contract Tests..."
export WSD_SOCKET_PATH="$SOCKET_PATH"
/opt/venv/bin/pytest tests/integration/test_wsd_api_signatures.py -v
exit_code=$?

# Cleanup
echo "Cleaning up WSD Agent..."
kill $AGENT_PID || true
rm -f "$SOCKET_PATH"

echo "Schema Test Runner finished with exit code $exit_code"
exit $exit_code
