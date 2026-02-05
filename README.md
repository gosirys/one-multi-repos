# Modular Repo Starter

> Scaffold a repo that pulls in **your** chosen Git submodules and keeps them up to date automatically.

---

## Rationale

When you manage a project that depends on a collection of independent Git repositories, keeping everything wired together and up to date can become tedious:

- You don't want to manually `git submodule add` every new dependency.  
- You want a single, uniform place to list your submodules.  
- You want daily automation to pull upstream changes and commit them back.

This template gives you all three out of the box:

1. **One-file list** (`submodules.txt`) — edit this list to add/remove dependencies.  
2. **Bootstrap script** (`scripts/init-submodules.sh`) — a single command to populate `modules/`.  
3. **Built-in GitHub Action** (`.github/workflows/update-submodules.yml`) — runs on a cron schedule to update pointers automatically.  
4. **Optional**: a `cookiecutter-template/` folder for interactive Cookiecutter users.

---

## Layout

```
/
├── .github/
│   └── workflows/
│       └── update-submodules.yml
├── scripts/
│   └── init-submodules.sh
├── submodules.txt.example
├── README.md                ← you are here
├── LICENSE
├── modules/                 ← (empty — populated by init-submodules.sh)
└── cookiecutter-template/   ← optional interactive template
    ├── cookiecutter.json
    └── {{cookiecutter.project_slug}}/
        ├── .github/
        │   └── workflows/update-submodules.yml
        ├── scripts/init-submodules.sh
        ├── submodules.txt.example
        └── README.md
```

---

## Prerequisites

This effectively only applies if you intend to use private repositories as your submodules. If that's not the case, you can skip this part.

### Public vs Private Repositories

#### Public submodules

You can use the default `${{ secrets.GITHUB_TOKEN }}` and configure `actions/checkout` to pull submodules recursively.

#### Private submodules
To use private repositories as submodules in GitHub Actions workflows (e.g., for automatically pulling submodule updates), you need to ensure the following:


- GitHub Pro or Higher Subscription: A GitHub Pro subscription (or higher, like GitHub Team or Enterprise) is required to use private repositories, including private submodules, in GitHub Actions workflows. Without this subscription, private repositories won't be accessible for these purposes.

- Access to Private Repositories: GitHub Actions can only access private repositories if the necessary permissions are granted. This requires enabling GitHub Actions for a private repository and setting up authentication (like a Personal Access Token or SSH key) for accessing the private submodule.

Steps:

1. Generate a Personal Access Token (PAT) in your GitHub account  
   - [Generate a Personal Access Token (PAT)](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token)
   - Go to **Settings → Developer settings → Personal access tokens (classic) → Generate new token**  
   - Name it, set an expiration if desired, and select the **repo** scope (or more narrowly, the `repo:status, repo_deployment, public_repo, repo:invite, repo:read` subset) scope so it can check out private repos.
   - Click **Generate token** and copy it immediately.

2. In your main repository's settings:  
   - **Secrets and variables → Actions** → [Add Repository Secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets)  
     - **Name:** `CUSTOM_PAT`  
     - **Value:** _your PAT_  
   - **Actions → General → Workflow permissions** → [Configure Workflow Permissions](https://docs.github.com/en/actions/security-guides/permissions-for-the-github_token)  
     - **Workflow permissions:** Read and write  
     - **Allow GitHub Actions to access:** Only select repositories - now **add** each private repository you want to use as a submodule.


---

### GitHub Token & Secrets

- **`GITHUB_TOKEN`** is automatically available in public repos; no setup needed.  
- **`CUSTOM_PAT`** (or your chosen name) must be added as a _repository secret_ in each repo that uses private submodules.  
- The Actions workflow uses `${{ secrets.CUSTOM_PAT }}` as the checkout token.

## Quickstart (Template Method)

1. **Use this template**  
   On GitHub click **Use this template**, name your new repo (e.g. `my-modular-project`), then clone it:
   ```bash
   git clone git@github.com:YOUR-ORG/my-modular-project.git
   cd my-modular-project
   ```

2. **Configure submodules**  
   ```bash
   cp submodules.txt.example submodules.txt
   # Edit submodules.txt — one Git URL per line:
   # https://github.com/foo.git
   # https://github.com/bar.git
   ```

3. **Bootstrap modules/**  

    This will add the submodules to the repo, configure the `CUSTOM_PAT` secret and grant the workflow its required permissions.
      ```bash
      chmod +x scripts/init-submodules.sh
      scripts/init-submodules.sh
      ```
    After that, the built-in GitHub Action in `.github/workflows/update-submodules.yml` runs on its schedule without further configuration.


4. **Link to GitHub**  

    if you already have a remote:
      ```bash
      git remote add origin git@github.com:YOUR-ORG/my-modular-project.git
      git push -u origin main
      ```

    Otherwise, create a new repo and link it:  
      ```bash
      gh repo create YOUR-ORG/my-modular-project \
        --public \
        --source=. \
        --remote=origin
      ```

5. **Verify CI**  
   GitHub Actions will pick up `.github/workflows/update-submodules.yml` and run on the defined cron schedule, updating your submodule pointers automatically.

---

## GitHub Actions

This workflow lives in `.github/workflows/update-submodules.yml`:

```yaml
name: Pull Submodules & Repackage

on:
  schedule:
    - cron: '58 18 * * *'    # adjust to your preferred UTC time
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
                git sparse-checkout init --cone
                IFS=',' read -ra path_array <<< "$paths"
                git sparse-checkout set "${path_array[@]}"
                popd > /dev/null
              fi
            done < "$SPARSE_CONFIG"
          fi

      - name: Commit changes in submodules
        # ... (commits any local changes in submodules)

      - name: Commit & push submodule pointer updates
        # ... (commits updated submodule pointers)
```

> **Note:**  
> - Uses either `CUSTOM_PAT` (for private submodules) or falls back to `GITHUB_TOKEN`.  
> - To support private submodules, ensure your PAT is configured as a secret as described above.
 
Read more on actions/checkout [here](https://github.com/actions/checkout)

---

## Customization

- **Submodule list**: edit `submodules.txt` and rerun `scripts/init-submodules.sh`.
- **Schedule**: adjust the `cron:` line in `.github/workflows/update-submodules.yml`.
- **CI steps**: add build/test jobs after the update steps.

---

## Selective Directory/File Sync

Instead of syncing entire repositories, you can choose to keep only specific directories or files from a submodule. This uses Git's **sparse checkout** feature.

### Configuration Format

In `submodules.txt`, append a colon and comma-separated paths to any repo URL:

```
# Full repo sync (default)
https://github.com/you/foo.git

# Selective sync - only specific directories/files
https://github.com/you/bar.git:src/,docs/,README.md
https://github.com/you/lib.git:lib/utils/,lib/helpers/,types.d.ts
```

### Rules

- **Directories** should end with `/` (e.g., `src/`, `docs/api/`)
- **Files** are specified by their path (e.g., `README.md`, `src/index.ts`)
- **Multiple paths** are separated by commas (no spaces)
- **Mode selection**: Automatically uses cone mode (faster) for directory-only configs, or non-cone mode when individual files are specified

### How It Works

1. The init script adds the submodule normally
2. It then configures sparse checkout with your specified paths
3. Only the specified directories/files are checked out to disk
4. The GitHub Action preserves the sparse checkout configuration on updates

### Configuration File

The sparse checkout settings are stored in `.sparse-checkout-config` at the repo root. This file is automatically generated and used by the GitHub Action to restore selective sync settings after updates.

```
# .sparse-checkout-config (auto-generated)
bar:src/,docs/,README.md
lib:lib/utils/,lib/helpers/,types.d.ts
```

### Example Use Cases

- **Only the `dist/` folder** from a dependency: `https://github.com/lib/build.git:dist/`
- **Documentation only**: `https://github.com/org/docs.git:docs/,README.md,CHANGELOG.md`
- **Specific modules**: `https://github.com/org/monorepo.git:packages/core/,packages/utils/`

---

## Cookiecutter Support (Optional)

If you want interactive scaffolding, run:

```bash
pip install cookiecutter
cookiecutter https://github.com/your-org/your-repo --directory cookiecutter-template
```

This will prompt for `project_slug` and `submodules` just as before.

---

## Summary

1. **scripts/init-submodules.sh** → single-command add/remove  
2. **.github/workflows/update-submodules.yml** → daily GitHub Actions automation  
3. **cookiecutter-template/** → optional interactive scaffolding  

Enjoy a modular, self-maintaining monorepo without the manual overhead!  
