# Preparing GitHub before the installers

Everything here happens in a web browser and can be done before the laptop or desktop is set up. Allow about 30 minutes.

Use two browser windows side by side:

- **Window A, signed in as you.** You own the organization and approve the agent's work.
- **Window B, a private/incognito window, signed in as the machine account.** The agent works as this account.

At the end you will have the five things stage 05 asks for (see [What to write down](#what-to-write-down)).

## 0. Decide: public or private repos

GitHub's protection rules (rulesets) are what stop the agent pushing to `main` or merging its own work. On a **free**
organization, rulesets are enforced on **public** repos only. On private repos they are shown but not enforced, and
GitHub displays a banner saying so.

| Your repos are | Do this |
| --- | --- |
| Public, or fine to make public | Free organization |
| Private | Upgrade the organization to **GitHub Team** (Organization settings → Billing and plans), or the protection in steps 6 and 7 protects nothing |

## 1. Create the organization (window A)

1. Click your avatar (top right) → **Your organizations** → **New organization**, then choose **Free** (or Team, see step 0).
2. **Organization name:** unique on GitHub. It becomes the URL (`github.com/<name>`) and the answer to the installer's
   "GitHub organisation" question. Lowercase letters, digits and hyphens are safest, for example `pdamuk-lab`.
3. **Contact email:** yours. **This organization belongs to:** *My personal account*.
4. Skip "Add organization members" for now.

You are now the organization's **owner**.

## 2. Organization settings (window A)

Open `github.com/organizations/<name>/settings`.

1. **Member privileges:**
   - **Base permissions: No permission.** Members then see only the repos a team gives them.
   - **Repository creation:** untick public and private. The agent has no reason to create repos.
   - **Repository forking:** leave off.
2. **Authentication security:** tick **Require two-factor authentication** for everyone in the organization (recommended).
3. **Personal access tokens** (under *Third-party Access*):
   - **Fine-grained tokens:** "Allow access via fine-grained personal access tokens", and "**Require administrator
     approval**". With approval on, no token reaches your repos until you say so.
   - **Tokens (classic):** "**Restrict access via personal access tokens (classic)**". Classic tokens cannot be limited
     to a few repos.
4. **Actions → General:**
   - **Workflow permissions:** leave **"Allow GitHub Actions to create and approve pull requests" unticked**. Otherwise a
     workflow could approve the agent's PR in your place.

## 3. Put the repos in the organization (window A)

- **New repo:** **+** → New repository → Owner: the organization.
- **Existing repo:** open it → **Settings** → **General** → scroll to **Danger Zone** → **Transfer ownership** → type the
  organization's name.
  - Issues, PRs, stars and history move with the repo, and the old URL redirects.
  - Still update your local clones: `git remote set-url origin https://github.com/<org>/<repo>.git`.

Each repo needs at least one commit on `main` (a README is enough). Rulesets protect the default branch, so it must exist.

**Do this step before step 5:** a team can only be given repos the organization already owns.

## 4. Create the machine account (window B)

The machine account is an ordinary second GitHub user account for the agent. GitHub's terms allow one per person, for automation.

1. In the private window, go to `github.com/signup`.
2. **Email:** an address different from your own account's. Gmail and most providers accept a plus alias, for example
   `yourname+hermes@gmail.com`; the mail still arrives in your inbox. Verify it.
3. **Username:** something that shows it is the agent, for example `pdamuk-hermes`. This is the "machine account name"
   the installer asks for.
4. **Two-factor authentication:** avatar → **Settings** → **Password and authentication** → **Enable two-factor
   authentication**, using an authenticator app. **Store the recovery codes** with the password, in a password manager.
5. Optional: Settings → **Public profile** → Name "Hermes (agent)", so its commits are easy to spot.

## 5. Give the machine account Write access (windows A, then B)

**Window A (you):**

1. Organization → **People** → **Invite member** → the machine account's username → role **Member** (not Owner) → **Send invitation**.
   - Do not add it as an *outside collaborator* on a repo instead. Fine-grained tokens do not work for outside collaborators.
2. Organization → **Teams** → **New team**:
   - Name `agents`. Visibility: *Visible* is fine.
   - **Create team**, then **Members** → **Add a member** → the machine account. It shows as pending until step 3 below.
3. The `agents` team → **Repositories** → **Add repository** → each repo the agent should work on, with role **Write**.
   - Write lets it push branches and open PRs. **Never Maintain or Admin:** those could change the rules.
   - **"No repositories found"?** This search lists only repos that **the organization owns**. Repos still under your
     personal account (`github.com/<you>/<repo>`) never appear here. Check `github.com/<org>?tab=repositories`:
     - **Empty:** do step 3 first (create or transfer the repos), then come back. A transfer can take a minute to show.
     - **Not empty:** make sure you are on the team page of the right organization (the organization name is at the top
       left), and type part of the repo's name: the box searches, it does not list everything.
   - **The other way round** gives the same result: open the repo → **Settings** → **Collaborators and teams** →
     **Add teams** → `agents` → role **Write**.

**Window B (machine account):**

4. Accept the invitation from the email, or at `github.com/orgs/<org>/invitation`.

**Check (window B):** open one of the repos. You should see **Code**, **Issues** and **Pull requests**, but **no
Settings tab**. A Settings tab means the role is too high.

## 6. Protect `main` (window A, on each repo)

Repo → **Settings** → **Rules** → **Rulesets** → **New ruleset** → **New branch ruleset**.

| Field | Value | Why |
| --- | --- | --- |
| Ruleset name | `protect main` | |
| **Enforcement status** | **Active** | New rulesets start as **Disabled** and then do nothing |
| Bypass list | empty. If you also open PRs yourself, add **Repository admin**, set to *For pull requests only* | Nobody can approve their own PR, so without this you could not merge your own. Never add the machine account or the `agents` team |
| Target branches | **Add target** → **Include default branch** | |
| Restrict deletions | on | |
| **Require a pull request before merging** | on | |
| ↳ Required approvals | **1** | The agent cannot approve its own PR, so you must |
| ↳ Dismiss stale pull request approvals when new commits are pushed | on | A push after your approval needs a new approval |
| ↳ Require approval of the most recent reviewable push | on | Without it, the agent could push after you approve and merge |
| Block force pushes | on | |
| Require status checks to pass | **leave off for now** | The check named `test` only exists after the CI workflow has run once. Add it after setup (stage 12, `tools/adopt-repo.sh`) |

Click **Create**. The ruleset list should show it as **Active**.

## 7. Protect release tags (window A, on each repo)

**New ruleset** → **New tag ruleset**.

| Field | Value |
| --- | --- |
| Ruleset name | `release tags` |
| **Enforcement status** | **Active** |
| Bypass list | **Repository admin** (that is you), *Always* |
| Target tags | **Add target** → **Include by pattern** → `v*` |
| Restrict updates | on (a published version cannot be moved) |
| Restrict deletions | on |
| Restrict creations | **off** (the release workflow creates new tags) |
| Block force pushes | on |

## 8. Create the agent's token (window B)

1. Avatar → **Settings** → **Developer settings** (at the bottom of the left menu) → **Personal access tokens** →
   **Fine-grained tokens** → **Generate new token**. Confirm with 2FA if asked.
2. Fill in the form:

   | Field | Value |
   | --- | --- |
   | Token name | `hermes-node` |
   | **Resource owner** | **the organization**, not the machine account. If the organization is missing from the list, the invitation is not accepted yet (step 5.4) or step 2.3 is not done |
   | Expiration | **90 days**. Put a reminder in your calendar a week before. To renew: generate a new token, then re-run stage 05 on the laptop |
   | Description | "Agent on the laptop node" |
   | Repository access | **Only select repositories** → the agent's repos |

3. **Repository permissions** (leave everything else at *No access*):

   | Permission | Access |
   | --- | --- |
   | Contents | Read and write |
   | Pull requests | Read and write |
   | Issues | Read and write |
   | Actions | Read-only |
   | Commit statuses | Read-only |
   | Metadata | Read-only (set automatically) |

   **Never grant** Workflows, Administration, Secrets, Environments, or any *Account permissions*.
   - Without Workflows, the agent cannot change CI to weaken it.
   - Without Administration, it cannot change the rules above.
4. **Generate token.** Copy the `github_pat_...` value into your password manager **now**: GitHub shows it only once.
   It is pending until you approve it in the next step.

## 9. Approve the token (window A)

Organization settings → **Personal access tokens** → **Pending requests** → the machine account's request → check the
repos and permissions match step 8 → **Approve**. Until then the token cannot see private repos, and stage 05 reports that.

## 10. The machine account's commit email (window B)

Settings → **Emails** → tick **Keep my email addresses private**. GitHub then shows an address like
`123456789+pdamuk-hermes@users.noreply.github.com`. Copy it: the agent's commits use it. Also tick **Block command line
pushes that expose my email**.

## What to write down

Stage 05 asks for these:

| Installer question | Example |
| --- | --- |
| GitHub organisation | `pdamuk-lab` |
| Repositories (space-separated, names only) | `api web` |
| Machine account name | `pdamuk-hermes` |
| Its noreply address | `123456789+pdamuk-hermes@users.noreply.github.com` |
| The token | `github_pat_...` (pasted when asked; never put it in `node.env`) |

## Check it worked

- **Before installing (window B, machine account):**
  - A repo shows no Settings tab.
  - On the repo's `main` branch, the web editor offers "Propose changes" (a branch and PR), not a direct commit.
- **After stage 05 (on the laptop):** `./setup.sh tool github-smoke-test`. It proves the agent can push a branch and open
  a PR, but cannot push to `main`, merge its own PR, or move a `v*` tag. **If anything that should be refused succeeds,
  stop and fix the ruleset before going on.**
