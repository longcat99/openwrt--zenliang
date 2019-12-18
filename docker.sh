#!/usr/bin/env bash

if [ "x$NO_FAILEXIT" != "x1" ]; then
  set -eo pipefail
fi

# helper functions
_exit_if_empty() {
  local var_name=${1}
  local var_value=${2}
  if [ -z "$var_value" ]; then
    echo "Missing input $var_name" >&2
    exit 1
  fi
}

_get_full_image_name() {
  echo ${REGISTRY:+$REGISTRY/}${IMAGE_NAME}
}

# action steps
check_required_input() {
  _exit_if_empty USERNAME "${USERNAME}"
  _exit_if_empty PASSWORD "${PASSWORD}"
  _exit_if_empty IMAGE_NAME "${IMAGE_NAME}"
  _exit_if_empty IMAGE_TAG "${IMAGE_TAG}"
  _exit_if_empty CONTEXT "${CONTEXT}"
  _exit_if_empty DOCKERFILE "${DOCKERFILE}"
}

configure_docker() {
  echo '{
    "max-concurrent-downloads": 50,
    "max-concurrent-uploads": 50
  }' | sudo tee /etc/docker/daemon.json
  sudo service docker restart
  docker buildx create --use --name builder --driver docker-container 
}

login_to_registry() {
  echo "${PASSWORD}" | docker login -u "${USERNAME}" --password-stdin "${REGISTRY}"
}

pull_image() {
  docker pull --all-tags "$(_get_full_image_name)" 2> /dev/null || true
}

build_image() {
  cache_from="$cache_from --cache-from=type=registry,ref=$(_get_full_image_name):buildcache"
  cache_to="$cache_to --cache-to=type=registry,ref=$(_get_full_image_name):buildcache,mode=max"
  echo "Use cache: $cache_from"
  echo "Export cache: $cache_to"

  build_target=()
  if [ ! -z "${1}" ]; then
    build_target+=(--target "${1}")
  fi
  build_args=()
  if [ ! -z "${BUILD_ARGS}" ]; then
    IFS_ORI="$IFS"
    IFS=$'\x20'
    
    for arg in ${BUILD_ARGS[@]};
    do
      build_args+=(--build-arg "${arg}=${!arg}")
    done
    IFS="$IFS_ORI"
  fi

  # build image using cache
  docker buildx build \
    "${build_target[@]}" \
    "${build_args[@]}" \
    $cache_from \
    $cache_to \
    --tag "$(_get_full_image_name)":${IMAGE_TAG} \
    --file ${CONTEXT}/${DOCKERFILE} \
    --load \
    ${CONTEXT}
}

copy_directory() {
  docker run -d -i --rm --name builder "$(_get_full_image_name)":${IMAGE_TAG}
  # docker exec builder stat "$1"
  docker cp builder:"$1" "$2"
}

push_git_tag() {
  [[ "$GITHUB_REF" =~ /tags/ ]] || return 0
  local git_tag=${GITHUB_REF##*/tags/}
  local image_with_git_tag
  image_with_git_tag="$(_get_full_image_name)":gittag-$git_tag
  docker tag "$(_get_full_image_name)":${IMAGE_TAG} "$image_with_git_tag"
  docker push "$image_with_git_tag"
}

push_image() {
  # push image
  docker push "$(_get_full_image_name)":${IMAGE_TAG}
  docker push "$(_get_full_image_name)":buildcache
  push_git_tag
}

logout_from_registry() {
  docker logout "${REGISTRY}"
}

check_required_input
