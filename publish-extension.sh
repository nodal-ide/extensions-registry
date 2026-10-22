#!/usr/bin/env bash

set -Eeuo pipefail

# Paths are resolved relative to the directory containing this script.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_ROOT="${SCRIPT_DIR}/samples/extensions"
REGISTRY_ROOT="${SCRIPT_DIR}/extensions-registry"

MANIFEST_PATH="${REGISTRY_ROOT}/extensions.json"
REGISTRY_EXTENSIONS_DIR="${REGISTRY_ROOT}/extensions"

usage() {
    cat <<'EOF'
Usage:
  ./publish-extension.sh --name=com.nodal.forge-pack

Options:
  --name=ID    Extension identifier matching extension.json
  --help       Show this help

The script reads:
  samples/extensions/<ID>/extension.json

It publishes:
  extensions-registry/extensions/<ID>/<VERSION>/<VERSION>.zip

It updates:
  extensions-registry/extensions.json
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*"
}

EXTENSION_ID=""

for argument in "$@"; do
    case "$argument" in
        --name=*)
            EXTENSION_ID="${argument#--name=}"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: ${argument}"
            ;;
    esac
done

[[ -n "$EXTENSION_ID" ]] || {
    usage >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required."
command -v shasum >/dev/null 2>&1 || die "shasum is required."
command -v zip >/dev/null 2>&1 || die "zip is required."
command -v unzip >/dev/null 2>&1 || die "unzip is required."

# Restrict the ID to the format accepted by the registry validator.
if [[ ! "$EXTENSION_ID" =~ ^[A-Za-z][A-Za-z0-9-]*([.][A-Za-z][A-Za-z0-9-]*)+$ ]]; then
    die "Invalid extension ID: ${EXTENSION_ID}"
fi

SOURCE_DIR="${SOURCE_ROOT}/${EXTENSION_ID}"
SOURCE_MANIFEST="${SOURCE_DIR}/extension.json"

[[ -d "$SOURCE_DIR" ]] || die "Extension directory not found: ${SOURCE_DIR}"
[[ -f "$SOURCE_MANIFEST" ]] || die "Missing extension.json: ${SOURCE_MANIFEST}"

# Validate and extract the source manifest.
jq -e --arg id "$EXTENSION_ID" '
    .schemaVersion == 2
    and .id == $id
    and (.name | type == "string" and length > 0)
    and (.description | type == "string" and length > 0)
    and (.version | type == "string" and length > 0)
    and (.author | type == "string" and length > 0)
' "$SOURCE_MANIFEST" >/dev/null \
    || die "extension.json is invalid or contains missing required fields."

EXTENSION_NAME="$(jq -er '.name' "$SOURCE_MANIFEST")"
EXTENSION_DESCRIPTION="$(jq -er '.description' "$SOURCE_MANIFEST")"
EXTENSION_PUBLISHER="$(jq -er '.author' "$SOURCE_MANIFEST")"
VERSION="$(jq -er '.version' "$SOURCE_MANIFEST")"

# Validate the version format accepted by the registry.
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$ ]]; then
    die "Invalid semantic version: ${VERSION}"
fi

# The registry validator accepts only lowercase SHA-256 hexadecimal.
# Reject build metadata only if your release policy requires it; the
# registry validator itself permits valid SemVer build metadata.
PACKAGE_DIR="${REGISTRY_EXTENSIONS_DIR}/${EXTENSION_ID}/${VERSION}"
PACKAGE_PATH="${PACKAGE_DIR}/${VERSION}.zip"
RELATIVE_PACKAGE_PATH="extensions/${EXTENSION_ID}/${VERSION}/${VERSION}.zip"

mkdir -p "$PACKAGE_DIR"
mkdir -p "$REGISTRY_ROOT"

# Do not overwrite an existing release.
[[ ! -e "$PACKAGE_PATH" ]] || die "Package already exists: ${PACKAGE_PATH}"

# Create a deterministic ZIP from the extension directory contents.
TEMP_PACKAGE="${PACKAGE_DIR}/.${VERSION}.zip.tmp"
TEMP_MANIFEST="$(mktemp "${REGISTRY_ROOT}/.extensions.json.XXXXXX")"

cleanup() {
    rm -f "$TEMP_PACKAGE" "$TEMP_MANIFEST"
}
trap cleanup EXIT

(
    cd "$SOURCE_DIR"
    zip -X -r "$TEMP_PACKAGE" . \
        -x "*/.DS_Store" ".DS_Store"
)

[[ -s "$TEMP_PACKAGE" ]] || die "ZIP package is empty."
unzip -tq "$TEMP_PACKAGE" >/dev/null || die "Generated ZIP is invalid."

INTEGRITY="$(shasum -a 256 "$TEMP_PACKAGE" | awk '{print $1}')"
PUBLISHED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Start with an empty registry if no manifest exists.
if [[ -f "$MANIFEST_PATH" ]]; then
    jq -e '
        .schemaVersion == 1
        and (.extensions | type == "object")
    ' "$MANIFEST_PATH" >/dev/null \
        || die "Existing registry manifest is invalid."
else
    printf '{"schemaVersion":1,"extensions":{}}\n' > "$TEMP_MANIFEST"
    cp "$TEMP_MANIFEST" "$MANIFEST_PATH"
fi

# Refuse to publish an existing version, even if the ZIP is missing.
if jq -e --arg id "$EXTENSION_ID" --arg version "$VERSION" \
    '.extensions[$id].versions[$version] != null' \
    "$MANIFEST_PATH" >/dev/null; then
    die "Version ${VERSION} already exists in the registry manifest."
fi

# Build a catalog entry from the extension metadata.
# Preserve existing releases and update only the latest version.
jq \
    --arg id "$EXTENSION_ID" \
    --arg name "$EXTENSION_NAME" \
    --arg description "$EXTENSION_DESCRIPTION" \
    --arg publisher "$EXTENSION_PUBLISHER" \
    --arg version "$VERSION" \
    --arg packageURL "$RELATIVE_PACKAGE_PATH" \
    --arg integrity "$INTEGRITY" \
    --arg publishedAt "$PUBLISHED_AT" \
    '
    .extensions[$id] = (
        (.extensions[$id] // {
            name: $name,
            description: $description,
            publisher: $publisher,
            url: null,
            latest: $version,
            versions: {}
        })
        | .name = $name
        | .description = $description
        | .publisher = $publisher
        | .versions[$version] = {
            url: $packageURL,
            integrity: $integrity,
            publishedAt: $publishedAt,
            nodal: null
        }
        | .latest = $version
    )
    ' "$MANIFEST_PATH" > "$TEMP_MANIFEST"

# Publish the package, then replace the manifest atomically.
mv "$TEMP_PACKAGE" "$PACKAGE_PATH"
mv "$TEMP_MANIFEST" "$MANIFEST_PATH"

log "Published extension: ${EXTENSION_ID}"
log "Version:             ${VERSION}"
log "Package:             ${PACKAGE_PATH}"
log "SHA-256:             ${INTEGRITY}"
log "Registry manifest:   ${MANIFEST_PATH}"