#!/bin/bash
set -Eeu

# installs runtime packages for CUDA image
#
# Required environment variables:
# - PYTHON_VERSION: Python version to install (e.g., 3.12)
# - CUDA_MAJOR: CUDA major version (e.g., 12)
# - CUDA_MINOR: CUDA minor version (e.g., 9)
# - TARGETOS: Target OS - either 'ubuntu' or 'rhel' (default: rhel)

TARGETOS="${TARGETOS:-rhel}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# source shared utilities (check script dir first, fallback to /tmp for docker builds)
UTILS_SCRIPT="${SCRIPT_DIR}/../common/package-utils.sh"
[ ! -f "$UTILS_SCRIPT" ] && UTILS_SCRIPT="/tmp/package-utils.sh"
if [ ! -f "$UTILS_SCRIPT" ]; then
    echo "ERROR: package-utils.sh not found" >&2
    exit 1
fi
# shellcheck source=docker/scripts/cuda/common/package-utils.sh
source "$UTILS_SCRIPT"

MAPPINGS_FILE=$(find_mappings_file "runtime-package-mappings.json" "$SCRIPT_DIR")
DOWNLOAD_ARCH=$(get_download_arch)

# main installation logic
if [ "$TARGETOS" = "ubuntu" ]; then
    setup_ubuntu_repos
    update_system ubuntu
    mapfile -t INSTALL_PKGS < <(load_and_expand_packages ubuntu "$MAPPINGS_FILE")
    install_packages ubuntu "${INSTALL_PKGS[@]}"
    cleanup_packages ubuntu

elif [ "$TARGETOS" = "rhel" ]; then
    setup_rhel_repos "$DOWNLOAD_ARCH"
    update_system rhel
    mapfile -t INSTALL_PKGS < <(load_and_expand_packages rhel "$MAPPINGS_FILE")
    install_packages rhel "${INSTALL_PKGS[@]}"
    cleanup_packages rhel

else
    echo "ERROR: Unsupported TARGETOS='$TARGETOS'. Must be 'ubuntu' or 'rhel'." >&2
    exit 1
fi
