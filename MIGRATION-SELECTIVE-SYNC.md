# Migration Guide: Add Selective Directory/File Sync

This guide enables upgrading a repo based on the Modular Repo Starter template to support selective syncing of specific directories/files from submodules (instead of entire repos).

## What This Adds

- Sync only specific directories or files from any submodule
- Configuration format: `repo_url:path1/,path2/,file.txt`
- Auto-persisted settings via `.sparse-checkout-config`
- GitHub Action automatically restores sparse checkout after updates

---

## Step 1: Update `scripts/init-submodules.sh`

Replace the entire file with:

```bash
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

	# Convert comma-separated paths to array
	local path_array
	IFS=',' read -ra path_array <<< "$paths"

	# Check if any path is a file (doesn't end with /)
	local has_files=false
	for p in "${path_array[@]}"; do
		if [[ "$p" != */ ]]; then
			has_files=true
			break
		fi
	done

	if $has_files; then
		# Use non-cone mode for file-level granularity
		git sparse-checkout init --no-cone
		git sparse-checkout set "${path_array[@]}"
	else
		# Use cone mode for directories (better performance)
		git sparse-checkout init --cone
		git sparse-checkout set "${path_array[@]}"
	fi

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
		repo="${line%:*}"
		# Handle case where URL has port (e.g., ssh://git@host:port/repo.git:paths)
		if [[ "$repo" != *".git" ]] && [[ "$repo" != *"/"* ]]; then
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
```

---

## Step 2: Update `.github/workflows/update-submodules.yml`

Replace the entire file with:

```yaml
name: Pull Submodules & Repackage

on:
  schedule:
    - cron: '58 18 * * *'    # adjust as needed
  workflow_dispatch:

jobs:
  update:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repo w/ submodules
        uses: actions/checkout@v3
        with:
          submodules: recursive
          token: ${{ secrets.CUSTOM_PAT || secrets.GITHUB_TOKEN }}

      - name: Configure Git
        run: |
          git config --local user.email "action@github.com"
          git config --local user.name "GitHub Action"

      - name: Pull main repo updates
        run: git pull origin $(git branch --show-current)

      - name: Update submodules
        run: |
          git submodule update --init --recursive --depth=1
          git submodule foreach --recursive '
            git fetch origin \
            && git reset --hard origin/$(git rev-parse --abbrev-ref HEAD) \
            || echo "Failed to reset submodule"'

      - name: Restore sparse checkout configuration
        run: |
          SPARSE_CONFIG=".sparse-checkout-config"
          if [[ -f "$SPARSE_CONFIG" ]]; then
            echo "Restoring sparse checkout configuration..."
            while IFS=':' read -r name paths; do
              [[ -z "$name" ]] && continue
              submodule_path="modules/$name"
              if [[ -d "$submodule_path" ]]; then
                echo "  → Configuring sparse checkout for $name: $paths"
                pushd "$submodule_path" > /dev/null

                IFS=',' read -ra path_array <<< "$paths"

                # Check if any path is a file (doesn't end with /)
                has_files=false
                for p in "${path_array[@]}"; do
                  if [[ "$p" != */ ]]; then
                    has_files=true
                    break
                  fi
                done

                if $has_files; then
                  git sparse-checkout init --no-cone
                else
                  git sparse-checkout init --cone
                fi
                git sparse-checkout set "${path_array[@]}"

                popd > /dev/null
              fi
            done < "$SPARSE_CONFIG"
            echo "✔ Sparse checkout configuration restored"
          else
            echo "No sparse checkout configuration found (full repo sync for all)"
          fi

      - name: Commit changes in submodules
        run: |
          git submodule foreach --recursive '
            if [ -n "$(git status --porcelain)" ]; then
              git add -A
              git commit -m "chore: auto-commit submodule changes in $(basename $PWD)"
              git push --force-with-lease || echo "Push failed in submodule $(basename $PWD)"
            else
              echo "No changes in submodule $(basename $PWD)"
            fi
          '

      - name: Commit & push submodule pointer updates
        run: |
          if ! git diff --quiet || ! git diff --staged --quiet; then
            git add .
            git commit -m "chore: update submodule pointers"
            git push --force-with-lease
          else
            echo "No submodule pointer updates to commit."
          fi
```

---

## Step 3: Update `submodules.txt` Configuration

The new format supports both full repo sync and selective sync:

```
# FULL REPO SYNC (default):
https://github.com/you/foo.git

# SELECTIVE SYNC - only keep specific directories/files:
# Format: repo_url:path1,path2,path3

# Examples:
https://github.com/you/bar.git:src/,docs/
https://github.com/you/baz.git:README.md,package.json,src/core/
https://github.com/you/lib.git:lib/utils/,lib/helpers/,types.d.ts

# Notes:
# - Directories should end with /
# - Multiple paths separated by commas (no spaces)
# - Auto-selects cone mode (dirs only) or non-cone mode (files included)
```

---

## Step 4: For Existing Submodules

If you already have submodules and want to enable selective sync:

1. Edit `submodules.txt` to add paths after the URL (e.g., `repo.git:src/,docs/`)

2. Manually configure sparse checkout for existing submodules:
   ```bash
   cd modules/<submodule-name>

   # For directories only:
   git sparse-checkout init --cone
   git sparse-checkout set src/ docs/

   # For files + directories:
   git sparse-checkout init --no-cone
   git sparse-checkout set src/ docs/ README.md
   ```

3. Create/update `.sparse-checkout-config` in repo root:
   ```
   submodule-name:src/,docs/,README.md
   ```

4. Commit the `.sparse-checkout-config` file so the GitHub Action can use it.

---

## Verification

Test that selective sync works:

```bash
# Check sparse checkout status for a submodule
cd modules/<name>
git sparse-checkout list

# Should only show your specified paths
ls -la  # Verify only selected files/dirs exist
```

---

## Summary

| File | Change |
|------|--------|
| `scripts/init-submodules.sh` | Added sparse checkout support |
| `.github/workflows/update-submodules.yml` | Added restore step |
| `submodules.txt` | New format: `url:path1,path2` |
| `.sparse-checkout-config` | Auto-generated config file |
