#!/usr/bin/env bash
set -Eeuo pipefail

: "${IMAGE_REGISTRY:?IMAGE_REGISTRY is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-}"
ENV_FILE="${ENV_FILE:-}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-xianyu-auto-reply}"
FULL_REGISTRY="${IMAGE_REGISTRY%/}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"

SERVICES=(backend-web websocket scheduler frontend)
declare -A CONTAINER_NAMES=(
    [backend-web]=xianyu-backend-web
    [websocket]=xianyu-websocket
    [scheduler]=xianyu-scheduler
    [frontend]=xianyu-frontend
)
declare -A OLD_IMAGE_IDS=()
declare -A OLD_IMAGE_REFS=()
UPDATED_SERVICES=()
ROLLBACK_FILE=""
LOCK_DIR=""

if [[ -z "$COMPOSE_FILE" ]]; then
    if [[ -f "$DEPLOY_DIR/docker-compose.deploy.yml" ]]; then
        COMPOSE_FILE="$DEPLOY_DIR/docker-compose.deploy.yml"
    elif [[ -f "$DEPLOY_DIR/docker-compose.remote.yml" ]]; then
        COMPOSE_FILE="$DEPLOY_DIR/docker-compose.remote.yml"
    else
        printf '[deploy] ERROR: no deployment compose file found in %s\n' "$DEPLOY_DIR" >&2
        exit 1
    fi
fi

if [[ -z "$ENV_FILE" ]]; then
    if [[ "$COMPOSE_FILE" == *docker-compose.remote.yml && -f "$DEPLOY_DIR/.env.remote" ]]; then
        ENV_FILE="$DEPLOY_DIR/.env.remote"
    else
        ENV_FILE="$DEPLOY_DIR/.env"
    fi
fi

log() {
    printf '[deploy] %s\n' "$*"
}

die() {
    printf '[deploy] ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ ! -f "$COMPOSE_FILE" ]]; then
    die "Compose file not found: $COMPOSE_FILE"
fi

if [[ ! -f "$ENV_FILE" ]]; then
    die "Environment file not found: $ENV_FILE. Run deploy.sh once on the server first."
fi

if docker compose version >/dev/null 2>&1; then
    DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose)
else
    die "Docker Compose is not installed"
fi

mkdir -p "$DEPLOY_DIR/.deploy"

if command -v flock >/dev/null 2>&1; then
    exec 9>"$DEPLOY_DIR/.deploy/deploy.lock"
    flock -n 9 || die "Another deployment is already running"
else
    LOCK_DIR="$DEPLOY_DIR/.deploy/deploy.lock.d"
    mkdir "$LOCK_DIR" 2>/dev/null || die "Another deployment is already running"
fi

cleanup() {
    if [[ -n "$LOCK_DIR" ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    if [[ -n "$ROLLBACK_FILE" ]]; then
        rm -f "$ROLLBACK_FILE" 2>/dev/null || true
    fi
}
trap cleanup EXIT

compose() {
    IMAGE_REGISTRY="$FULL_REGISTRY" IMAGE_TAG="$IMAGE_TAG" COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
        "${DC[@]}" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

compose_with_override() {
    local override_file="$1"
    shift
    IMAGE_REGISTRY="$FULL_REGISTRY" IMAGE_TAG="$IMAGE_TAG" COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
        "${DC[@]}" -f "$COMPOSE_FILE" -f "$override_file" --env-file "$ENV_FILE" "$@"
}

record_current_images() {
    local service container
    for service in "${SERVICES[@]}"; do
        container="${CONTAINER_NAMES[$service]}"
        if docker inspect "$container" >/dev/null 2>&1; then
            OLD_IMAGE_IDS[$service]="$(docker inspect --format '{{.Image}}' "$container")"
            OLD_IMAGE_REFS[$service]="$(docker inspect --format '{{.Config.Image}}' "$container")"
            log "Current $service image: ${OLD_IMAGE_REFS[$service]}"
        fi
    done
}

wait_for_service() {
    local service="$1"
    local container="${CONTAINER_NAMES[$service]}"
    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    local no_health_since=0

    while (( SECONDS < deadline )); do
        if ! docker inspect "$container" >/dev/null 2>&1; then
            sleep 2
            continue
        fi

        local state health
        state="$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)"
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"

        if [[ "$health" == "healthy" ]]; then
            log "$service is healthy"
            return 0
        fi

        if [[ "$health" == "unhealthy" || "$state" == "exited" || "$state" == "dead" ]]; then
            docker logs --tail 80 "$container" >&2 || true
            return 1
        fi

        if [[ "$health" == "none" && "$state" == "running" ]]; then
            if (( no_health_since == 0 )); then
                no_health_since=$SECONDS
            elif (( SECONDS - no_health_since >= 10 )); then
                log "$service is running (no Docker healthcheck exposed)"
                return 0
            fi
        else
            no_health_since=0
        fi

        sleep 2
    done

    docker logs --tail 80 "$container" >&2 || true
    return 1
}

write_rollback_file() {
    ROLLBACK_FILE="$(mktemp "$DEPLOY_DIR/.deploy/rollback.XXXXXX.yml")"
    printf 'services:\n' > "$ROLLBACK_FILE"

    local service ref image_id
    for service in "${UPDATED_SERVICES[@]}"; do
        ref="${OLD_IMAGE_REFS[$service]-}"
        image_id="${OLD_IMAGE_IDS[$service]-}"
        if [[ -z "$ref" ]]; then
            continue
        fi
        if [[ -n "$image_id" ]]; then
            docker tag "$image_id" "$ref" 2>/dev/null || true
        fi
        printf '  %s:\n    image: %s\n' "$service" "$ref" >> "$ROLLBACK_FILE"
    done
}

rollback() {
    local service
    local rollback_services=()

    for service in "${UPDATED_SERVICES[@]}"; do
        if [[ -n "${OLD_IMAGE_REFS[$service]-}" ]]; then
            rollback_services+=("$service")
        fi
    done

    if (( ${#rollback_services[@]} == 0 )); then
        log "No previous application containers available for rollback"
        return 0
    fi

    log "Deployment failed; restoring the previous images"
    write_rollback_file
    compose_with_override "$ROLLBACK_FILE" up -d --no-deps --force-recreate "${rollback_services[@]}" || true

    for service in "${rollback_services[@]}"; do
        wait_for_service "$service" || true
    done
}

on_error() {
    local status=$?
    trap - ERR
    rollback || true
    exit "$status"
}
trap on_error ERR

log "Using image registry $FULL_REGISTRY and tag $IMAGE_TAG"
log "Starting infrastructure without stopping existing containers"
for infrastructure in mysql redis; do
    if compose config --services 2>/dev/null | grep -qx "$infrastructure"; then
        compose up -d --no-recreate "$infrastructure"
    fi
done

record_current_images

log "Pulling the new application images while the current release keeps running"
compose pull "${SERVICES[@]}"

for service in backend-web websocket scheduler frontend; do
    UPDATED_SERVICES+=("$service")
    log "Switching $service"
    compose up -d --no-deps --force-recreate "$service"
    wait_for_service "$service"
done

upsert_env() {
    local key="$1"
    local value="$2"
    if grep -qE "^${key}=" "$ENV_FILE"; then
        sed -i -E "s|^${key}=.*$|${key}=${value}|" "$ENV_FILE"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

upsert_env IMAGE_REGISTRY "$FULL_REGISTRY"
upsert_env IMAGE_TAG "$IMAGE_TAG"

log "Deployment completed without docker compose down"
compose ps
