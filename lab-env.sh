#!/usr/bin/env bash

set -e

version="0.1.0-a1"
rev="fe3a8e759573034ec7aa304dd6a31904efb04fc8"

cat <<"EOF"
      __      __                         
     / /___ _/ /_        ___  ____ _   __
    / / __ `/ __ \______/ _ \/ __ \ | / /
   / / /_/ / /_/ /_____/  __/ / / / |/ / 
  /_/\__,_/_.___/      \___/_/ /_/|___/  
EOF
printf "%41s\n" "version $version"
if [ ! -z "$rev" ]; then
  printf "%41s\n" "rev ${rev:0:7}"
fi
printf "\n"

# Silence pushd and popd
pushd () {
    command pushd "$@" > /dev/null
}
popd () {
    command popd "$@" > /dev/null
}

function exitWithError() {
  printf "ERROR:\n"
  printf "%4s%s\n" " " "$1"
  exit 1
}

function onExit() {
  if [ -z DOCKER_CONTAINER_ID ]; then
    docker kill 2>/dev/null $DOCKER_CONTAINER_ID || true
  fi
}

function has() { 
  hash "$1" 2>/dev/null; 
};

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CONF_DIR="$LAB_DIR/lab-env"

function init() {
  if ! has nix; then
    exitWithError "nix is required to init, build, and publish lab-env environments"
  fi
  if [ -z $1 ]; then
    local NEW_LAB_PATH="$PWD"
  else
    if [ ! -d "$1" ]; then
      exitWithError "'$1' is not a directory"
    fi
    local NEW_LAB_PATH="$(cd "$1"; pwd)"
  fi
  printf "Initialising lab for path $NEW_LAB_PATH...\n"
  
  if ! $(mkdir -p "$NEW_LAB_PATH/lab-env"); then
    exitWithError "lab already initialised in $NEW_LAB_PATH. Delete the lab-env dir to start from scratch"
  fi

  local NEW_LAB_CONF_DIR="$NEW_LAB_PATH/lab-env"

  cat > "$NEW_LAB_CONF_DIR/publish-conf.json" <<"EOF"
{
  "docker": {
     "repo": ""
  }
}
EOF
  
  cat > "$NEW_LAB_CONF_DIR/lab-env.nix" <<EOF
let 
  lab-env = import (builtins.fetchGit {
    url = "https://github.com/adam-roughton/lab-env";
EOF
if [ -z "$rev" ]; then
  echo "    ref = \""$version"\";" >> "$NEW_LAB_CONF_DIR/lab-env.nix"   
else
  echo "    rev = \""$rev"\";" >> "$NEW_LAB_CONF_DIR/lab-env.nix"
fi
cat >>  "$NEW_LAB_CONF_DIR/lab-env.nix" <<EOF
   }) {};
in with lab-env;
  buildJupyterLab {
    spark = mkSparkDist {
      sparkVersion = "2.4.3";
    };
  }
EOF
  cp "${BASH_SOURCE[0]}" "$NEW_LAB_PATH"
}

function runLab() {
  printf "Loading lab for path $LAB_DIR...\n"

  if has nix; then
    DEFAULT_RUNTIME=nix
  elif has docker; then
    DEFAULT_RUNTIME=docker
  fi

  case $1 in
    -r|--runtime)
      shift
      RUNTIME="$1"
      ;;
  esac 

  RUNTIME="${RUNTIME:-${DEFAULT_RUNTIME}}"
  case $RUNTIME in
    nix)
      if ! has nix; then 
        exitWithError "nix requested but not installed"
      fi
      ;;
    docker)
      if ! has docker; then 
        exitWithError "docker requested but missing from the path"
      fi
      ;;
    *)
      exitWithError "unknown runtime '$RUNTIME'"
      ;;
  esac

  if [ $RUNTIME == "nix" ]; then
    nix-shell -E "(import $CONF_DIR/lab-env.nix).env" --command "jupyter lab" 
  else
    PUBLISHED_SHA_FILE="$CONF_DIR/published-sha"
    if [ ! -f $PUBLISHED_SHA_FILE ]; then
      exitWithError "this environment has not been published - unable to fetch docker images"
    fi
    PUBLISHED_SHA=$(<$PUBLISHED_SHA_FILE)
    if [[ $PUBLISHED_SHA =~ "^(0-9a-b){64}$" ]]; then
      exitWithError "the publish sha was malformed"
    fi
    PUBLISH_CONF_FILE="$CONF_DIR/publish-conf.json"
    if [ ! -f $PUBLISH_CONF_FILE ]; then
      exitWithError "missing publish-conf.json! This lab may not have been published correctly"
    fi
    
    if ! hash jq 2>/dev/null; then
      exitWithError "lab-env has a dependency on jq - ensure it's installed and on the PATH"
    fi

    PUBLISH_REPO=$(cat $PUBLISH_CONF_FILE | jq -r .docker.repo)
    if [ -z $PUBLISH_REPO ]; then
      exitWithError "could not find the key docker.repo in publish-conf.json"
    fi

    DOCKER_CONTAINER_ID=$(docker run -d \
      -p 8888:8888 \
      -p 4040-4060:4040-4060 \
      -v $LAB_DIR:/data \
      "$PUBLISH_REPO:$PUBLISHED_SHA")
    if [ ! $? ]; then
      exitWithError "Failed to start docker container (ports in use?)"
    fi

    # Wait for the port to be ready
    printf "Waiting for the lab to start\n"
    count=10
    until [ $count -lt 0 ] || $(curl --output /dev/null --silent --fail http://localhost:8888/); do
      printf .
      sleep 1
      count=$(($count - 1))
    done
    printf '\n'

    if $(curl --output /dev/null --silent --fail http://localhost:8888/); then
      if hash xdg-open 2>/dev/null; then
        xdg-open "http://localhost:8888"
      elif hash open 2>/dev/null; then
        open "http://localhost:8888"
      else
        echo "Lab running on http://localhost:8888"
      fi
    else
      echo "Timed out waiting for the lab to start. It should (eventually) be running on http://localhost:8888"
    fi

    docker attach $DOCKER_CONTAINER_ID
  fi
}

function buildLab() {
  if ! has nix || ! has docker; then
    exitWithError "nix and docker are required to build lab-env environments"
  fi
  pushd "$LAB_DIR"
  nix-build -o build -E "(import $CONF_DIR/lab-env.nix).dockerImages { publishConfFile = $CONF_DIR/publish-conf.json; }"
  ./build/load-images.sh
  popd
}

function publishLab() {
  buildLab
  if ! has docker; then
    exitWithError "docker is required to publish lab-env environments"
  fi
  "$LAB_DIR/build/publish.sh"
  cat "$LAB_DIR/build/buildId" >| "$CONF_DIR/published-sha"
}

function clean() {
  printf "Cleaning lab directory...\n"
  if [ -e "$LAB_DIR/build" ]; then 
    rm "$LAB_DIR/build"
  fi
}

case $1 in
  init)
    shift
    init $@
    ;;
  run)
    shift
    runLab $@
    ;;
  build)
    shift
    buildLab $@
    ;;
  publish)
    shift
    publishLab $@
    ;;
  clean)
    shift
    clean $@
    ;;
  *)
    # any unrecognised command, just try and run
    runLab $@
    ;;
esac 

