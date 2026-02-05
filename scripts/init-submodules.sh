#!/usr/bin/env bash
set -euo pipefail

CONFIG=submodules.txt
TARGET=modules
SPARSE_CONFIG=".sparse-checkout-config"

# Ensure GitHub CLI is available and authenticated
if ! command -v gh &>/dev/null; then
	echo "✖ Install and authenticate GitHub CLI: https://cli.github.com/"
	exit 1
fi

# Prompt for a PAT (repo scope)
read -rsp "Enter your GitHub PAT (repo scope): " SUBMODULE_PAT
echo

# Store PAT as a repository secret in the new repo
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
gh secret set SUBMODULE_PAT --body "$SUBMODULE_PAT" --repo "$REPO"

# Grant Actions permission and whitelist private submodules
# Adjust PRIVATE_SUBMODULES array if specific repos need to be selected
PRIVATE_SUBMODULES=()
# Example: PRIVATE_SUBMODULES+=( "org/repo-one" "org/repo-two" )

gh api \
	-X PUT "/repos/$REPO/actions/permissions/workflow" \
	-f default_workflow_permissions=write \
	-f allowed_actions=selected \
	-f selected_repositories="$(printf '%s\n' "${PRIVATE_SUBMODULES[@]}" | paste -sd, -)" \
	--silent

echo "✔ SUBMODULE_PAT secret created and workflow permissions updated."

# Add each repository listed in submodules.txt
if [[ ! -f "$CONFIG" ]]; then
	echo "✖ Copy submodules.txt.example to submodules.txt and edit it"
	exit 1
fi

# Function to configure sparse checkout for a submodule
configure_sparse_checkout() {
	local submodule_path="$1"
	local paths="$2"

	echo "  → Configuring sparse checkout for: $paths"

	pushd "$submodule_path" > /dev/null

	# Enable sparse checkout
	git sparse-checkout init --cone

	# Convert comma-separated paths to space-separated for sparse-checkout set
	local path_array
	IFS=',' read -ra path_array <<< "$paths"

	# Set the sparse checkout paths
	git sparse-checkout set "${path_array[@]}"

	popd > /dev/null
}

mkdir -p "$TARGET"

# Clear and prepare sparse config file for tracking selective repos
> "$SPARSE_CONFIG"

while IFS=$'\n' read -r line; do
	[[ -z "$line" || "${line:0:1}" == "#" ]] && continue

	# Check if line contains selective paths (format: repo_url:path1,path2,path3)
	if [[ "$line" == *":"*"/"* ]] || [[ "$line" == *":"*","* ]]; then
		# Extract repo URL (everything before the last colon that's followed by paths)
		# Handle URLs like https://github.com/user/repo.git:src/,docs/
		repo="${line%:*}"
		# Handle case where URL has port (e.g., ssh://git@host:port/repo.git:paths)
		if [[ "$repo" != *".git" ]] && [[ "$repo" != *"/"* ]]; then
			# Colon was part of URL, not path separator - this is a full repo
			repo="$line"
			paths=""
		else
			paths="${line##*:}"
		fi
	else
		repo="$line"
		paths=""
	fi

	name=$(basename -s .git "$repo")

	if [[ -n "$paths" ]]; then
		echo "⤷ Adding $name from $repo (selective: $paths)"
		# Store sparse config for this submodule
		echo "$name:$paths" >> "$SPARSE_CONFIG"
	else
		echo "⤷ Adding $name from $repo (full repo)"
	fi

	git submodule add "$repo" "$TARGET/$name"

	# Configure sparse checkout if selective paths specified
	if [[ -n "$paths" ]]; then
		git submodule update --init "$TARGET/$name"
		configure_sparse_checkout "$TARGET/$name" "$paths"
	fi
done < "$CONFIG"

git submodule update --init --recursive
echo "✔ All submodules added under $TARGET/"

if [[ -s "$SPARSE_CONFIG" ]]; then
	echo "✔ Sparse checkout configured for selective repos (config saved in $SPARSE_CONFIG)"
fi