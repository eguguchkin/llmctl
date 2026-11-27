ENGINE=stub
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_IMAGE="ghcr.io/example/stub:0"
ENGINE_PORT_DEFAULT=11999
ENGINE_CONTAINER=stub_stub_1
ENGINE_POD=pod_stub
ENGINE_PROJECT=stub
ENGINE_COMPOSE_FILES=( -f compose.yml )
ENGINE_ENV_TEMPLATE="$ADAPTER_DIR/tpl/env.tpl"
ENGINE_MEMLOCK=1024
ENGINE_FAIL_PATTERN="boom"
PROFILE_LIST="stub-p"; PROFILE_DEFAULT=stub-p
profile_stub_p="m|m|-|1|stub"
engine_model_set() { echo 27b; }
engine_health_ok() { return 1; }
