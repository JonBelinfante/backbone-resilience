# script-kind: library
# Purpose: Run the Python checkers (ruff, mypy, pytest) in a container with fixed versions.
# Usage: source "${SCRIPT_DIR}../lib/pytools.sh", then call pytools::ensure_image and pytools::run
# Requires: docker
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly PYTOOLS_IMAGE='resilience-python-tools'

# Build the tools image from the folder holding its Dockerfile, unless it already exists.
# Usage: pytools::ensure_image DOCKERFILE_FOLDER
pytools::ensure_image() {
  local folder="${1:?folder required}"

  if docker image inspect "${PYTOOLS_IMAGE}" > /dev/null 2>&1; then
    log INFO "${PYTOOLS_IMAGE} is already built"
    return 0
  fi
  log INFO "CHANGE: building ${PYTOOLS_IMAGE} from ${folder}"
  docker build --quiet --tag "${PYTOOLS_IMAGE}" "${folder}" > /dev/null
}

# Run a command in the tools image with the repository mounted read-only at /work, which is also
# the working folder, so pyproject.toml is found. The tools' caches go to a temporary file
# system. The command is the arguments after the folder.
# Usage: pytools::run REPOSITORY_FOLDER COMMAND [ARGUMENT ...]
pytools::run() {
  local folder="${1:?repository folder required}"
  local -a command=(docker run --rm)

  command+=(--volume "${folder}:/work:ro" --tmpfs /cache)
  command+=(--env MYPY_CACHE_DIR=/cache/mypy --env RUFF_CACHE_DIR=/cache/ruff)
  command+=(--env PYTHONDONTWRITEBYTECODE=1)
  command+=("${PYTOOLS_IMAGE}" "${@:2}")
  "${command[@]}"
}
