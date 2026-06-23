# === Defaults Variables ===
FILES=""
TARGET_BRANCH="main"
COMMIT_MESSAGE="chore: update files [skip ci]"
COMMIT_AUTHOR_NAME="github-actions[bot]"
COMMIT_AUTHOR_EMAIL="github-actions[bot]@users.noreply.github.com"
AUTH_METHOD="token"
GITHUB_HOSTNAME="github.com"
MAX_RETRIES=3
BACKOFF=5

set -e

# === Parse Options ===
while [ "$#" -gt 0 ]; do
  case "$1" in
    --files) FILES="$2"; shift 2 ;;
    --target-repo) TARGET_REPO="$2"; shift 2 ;;
    --target-branch) TARGET_BRANCH="$2"; shift 2 ;;
    --commit-message) COMMIT_MESSAGE="$2"; shift 2 ;;
    --commit-author-name) COMMIT_AUTHOR_NAME="$2"; shift 2 ;;
    --commit-author-email) COMMIT_AUTHOR_EMAIL="$2"; shift 2 ;;
    --auth-method) AUTH_METHOD="$2"; shift 2 ;;
    --github-token) GITHUB_TOKEN="$2"; shift 2 ;;
    --github-hostname) GITHUB_HOSTNAME="$2"; shift 2 ;;
    --max-retries) MAX_RETRIES="${2:-$MAX_RETRIES}"; shift 2 ;;
    --backoff) BACKOFF="${2:-$BACKOFF}"; shift 2 ;;
    \?) echo "::error::Invalid options $1" >&2; exit 1 ;;
  esac
done

# Build Clone URL
case "${AUTH_METHOD}" in
  token)
    if [ -z "${GITHUB_TOKEN}" ]; then
      echo "::error::github-token is required when auth-method is 'token'"
      exit 1
    fi
    CLONE_URL="https://x-access-token:${GITHUB_TOKEN}@${GITHUB_HOSTNAME}/${TARGET_REPO}.git"
    ;;
  ssh)
    CLONE_URL="git@${GITHUB_HOSTNAME}:${TARGET_REPO}.git"
    ;;
  none)
    CLONE_URL="https://${GITHUB_HOSTNAME}/${TARGET_REPO}.git"
    ;;
esac

# No files to commit if files variable is empty
if [ -z "${FILES}" ]; then
  echo "::warning::No files provided."
  echo "committed=false" >> "$GITHUB_OUTPUT"
  echo "files_count=0" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Clone target repo (shallow)
TEMP_DIR=$(mktemp -d)
REPO_DIR="${TEMP_DIR}/repo"
echo "Cloning ${TARGET_REPO} (branch: ${TARGET_BRANCH})..."
CLONE_EXIT_FILE=$(mktemp)
{ git clone --depth 1 --single-branch --branch "${TARGET_BRANCH}" \
  "${CLONE_URL}" "${REPO_DIR}" 2>&1; echo $? > "${CLONE_EXIT_FILE}"; } | grep -v "x-access-token" || true
CLONE_EXIT=$(cat "${CLONE_EXIT_FILE}")
rm -f "${CLONE_EXIT_FILE}"
if [ "${CLONE_EXIT}" -ne 0 ]; then
  echo "::error::Failed to clone ${TARGET_REPO} (branch: ${TARGET_BRANCH})"
  exit "${CLONE_EXIT}"
fi

# Copy files to repo
printf '%s\n' "${FILES}" > "${TEMP_DIR}/files_list.txt"
COUNT=0
while IFS= read -r LINE; do
  # Skip empty lines and comments
  case "${LINE}" in
    ""|\#*) continue ;;
  esac

  # Split on the last colon to support paths with colons (unlikely but safe)
  # Format: source:destination
  SRC=$(echo "${LINE}" | sed 's|:[^:]*$||')
  DST=$(echo "${LINE}" | sed 's|.*:||')

  # Validate source and destination are not empty
  if [ -z "${SRC}" ] || [ -z "${DST}" ]; then
    echo "::warning::Skipping invalid mapping (expected source:destination): ${LINE}"
    continue
  fi

  # Check if source exists
  if [ ! -e "${SRC}" ]; then
    echo "::error::Source not found: ${SRC} for mapping ${LINE}"
    exit 1
  fi

  # Handle file or directory
  if [ -d "${SRC}" ]; then
    # Source is a directory: copy recursively
    mkdir -p "${REPO_DIR}/${DST}"
    cp -r "${SRC}/." "${REPO_DIR}/${DST}/"
    git -C "${REPO_DIR}" add "${DST}"
    COUNT=$((COUNT + 1))
    echo "Mapped (dir): ${SRC} -> ${DST}"
  else
    # Source is a file
    DST_DIR=$(dirname "${DST}")
    mkdir -p "${REPO_DIR}/${DST_DIR}"
    cp "${SRC}" "${REPO_DIR}/${DST}"
    git -C "${REPO_DIR}" add "${DST}"
    COUNT=$((COUNT + 1))
    echo "Mapped: ${SRC} -> ${DST}"
  fi
done < "${TEMP_DIR}/files_list.txt"

echo "files_count=${COUNT}" >> "$GITHUB_OUTPUT"
echo "Processed ${COUNT} file(s)"

# Commit and push changes
if [ "${COUNT}" -gt 0 ]; then
  if git -C "${REPO_DIR}" diff --cached --quiet; then
    echo "::notice::All files are unchanged, no commit needed"
    echo "committed=false" >> "$GITHUB_OUTPUT"
  else
    # Configure git author
    cd "${REPO_DIR}"
    git config user.name "${COMMIT_AUTHOR_NAME}"
    git config user.email "${COMMIT_AUTHOR_EMAIL}"

    git commit -m "${COMMIT_MESSAGE}"

    retry=0
    while [ "$retry" -lt "${MAX_RETRIES}" ]; do
      ATTEMPT=$((retry + 1))
      echo "Attempt ${ATTEMPT}/${MAX_RETRIES}"
      echo "Pushing to ${TARGET_REPO}@${TARGET_BRANCH}..."
      PUSH_EXIT_FILE=$(mktemp)
      { git push origin "${TARGET_BRANCH}" 2>&1; echo $? > "${PUSH_EXIT_FILE}"; } | grep -v "x-access-token" || true
      PUSH_EXIT=$(cat "${PUSH_EXIT_FILE}")
      rm -f "${PUSH_EXIT_FILE}"
      if [ "${PUSH_EXIT}" -eq 0 ]; then
        echo "committed=true" >> "$GITHUB_OUTPUT"
        echo "::notice::Files committed and pushed successfully"
        exit 0
      fi

      echo "Push failed, rebasing..."
      git pull --rebase --autostash origin "${TARGET_BRANCH}"

      # Backoff with jitter
      SLEEP_TIME=$BACKOFF_BASE
      i=0
      while [ "$i" -lt "$retry" ]; do
        SLEEP_TIME=$((SLEEP_TIME * 2))
        i=$((i + 1))
      done
      JITTER=$(($(date +%s) % 3))
      TOTAL_SLEEP=$((SLEEP_TIME + JITTER))
      echo "Retrying in ${TOTAL_SLEEP}s..."
      sleep "${TOTAL_SLEEP}"
      retry=$ATTEMPT
    done

    # Cleanup
    rm -rf "${TEMP_DIR}" 2>/dev/null || true

    # Failed after max retries
    echo "::error::Failed to push to ${TARGET_REPO} after ${MAX_RETRIES} attempts"
    exit 1
  fi
else
  echo "::notice::No files to commit after processing"
  echo "committed=false" >> "$GITHUB_OUTPUT"
fi

# Cleanup
rm -rf "${TEMP_DIR}" 2>/dev/null || true
