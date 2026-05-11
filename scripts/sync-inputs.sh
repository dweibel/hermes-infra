#!/bin/bash
set -euo pipefail

# Sync the job-search-pipeline Inputs directory to the OCI Hermes instance.
# The Hermes container mounts /mnt/workspace/hermes as /opt/data.
# The job-search-pipeline lives at /opt/data/job-search-pipeline/ inside the container.
#
# Usage:
#   ./scripts/sync-inputs.sh                            # run locally
#   ./scripts/sync-inputs.sh /path/to/job-search-pipeline  # custom source path
#
# Prerequisites:
#   - SSH access to oci-agent configured in ~/.ssh/config
#   - job-search-pipeline exists locally

LOCAL_PIPELINE="${1:-$(dirname "$(dirname "$(realpath "$0")")")/../job-search-pipeline}"
REMOTE_BASE="/mnt/workspace/hermes/job-search-pipeline"

# Resolve the local path
if [ ! -d "$LOCAL_PIPELINE/Inputs" ]; then
    echo "ERROR: Cannot find Inputs directory at $LOCAL_PIPELINE/Inputs"
    echo "Usage: $0 /path/to/job-search-pipeline"
    exit 1
fi

echo "=== Syncing Inputs to OCI Hermes ==="
echo "Source: $LOCAL_PIPELINE/Inputs/"
echo "Target: oci-agent:$REMOTE_BASE/Inputs/"
echo ""

# Ensure remote directory structure exists
ssh oci-agent "mkdir -p $REMOTE_BASE/Inputs/narratives"

# Sync the experience bank index
echo "Syncing experience-bank.yaml..."
scp "$LOCAL_PIPELINE/Inputs/experience-bank.yaml" "oci-agent:$REMOTE_BASE/Inputs/experience-bank.yaml"

# Sync all narrative files
echo "Syncing narratives/..."
scp "$LOCAL_PIPELINE/Inputs/narratives/"*.md "oci-agent:$REMOTE_BASE/Inputs/narratives/"

# Sync other input files if they exist
for file in resume.md cover-letter.md preferences.md; do
    if [ -f "$LOCAL_PIPELINE/Inputs/$file" ]; then
        echo "Syncing $file..."
        scp "$LOCAL_PIPELINE/Inputs/$file" "oci-agent:$REMOTE_BASE/Inputs/$file"
    fi
done

# Also sync Memory directory structure (create if missing, don't overwrite existing data)
echo ""
echo "Ensuring Memory directory exists on remote..."
ssh oci-agent "mkdir -p $REMOTE_BASE/Memory"

# Only copy Memory files if they don't already exist on remote (don't overwrite live state)
for file in lead-tracker.md closed-leads-archive.md funnel-analytics.md; do
    ssh oci-agent "[ -f $REMOTE_BASE/Memory/$file ] || echo 'MISSING'" | grep -q MISSING && {
        echo "Creating $file (did not exist on remote)..."
        scp "$LOCAL_PIPELINE/Memory/$file" "oci-agent:$REMOTE_BASE/Memory/$file"
    } || echo "Skipping Memory/$file (already exists on remote)"
done

echo ""
echo "=== Sync complete ==="
echo ""
echo "Verify inside container:"
echo "  ssh oci-agent 'podman exec hermes-agent ls /opt/data/job-search-pipeline/Inputs/'"
echo "  ssh oci-agent 'podman exec hermes-agent ls /opt/data/job-search-pipeline/Inputs/narratives/'"
