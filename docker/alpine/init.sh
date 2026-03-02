#!/bin/sh

set -e

# Ensure configuration exists
if [ ! -f "/config/settings.json" ]; then
  cp -a /defaults/settings.json /config/settings.json
fi

# Extract config file path from arguments
config_file=""
next_is_config=0
for arg in "$@"; do
  if [ "$next_is_config" -eq 1 ]; then
    config_file="$arg"
    break
  fi
  case "$arg" in
    -c|--config)
      next_is_config=1
      ;;
    -c=*|--config=*)
      config_file="${arg#*=}"
      break
      ;;
  esac
done

# If no config argument is provided, set the default and add it to the args
if [ -z "$config_file" ]; then
  config_file="/config/settings.json"
  set -- --config=/config/settings.json "$@"
fi

# Apply auth configuration from environment variables if set
if [ -n "$FB_AUTH_METHOD" ]; then
  AUTH_ARGS="--auth.method=${FB_AUTH_METHOD}"
  if [ -n "$FB_AUTH_HEADER" ]; then
    AUTH_ARGS="$AUTH_ARGS --auth.header=${FB_AUTH_HEADER}"
  fi
  if [ -n "$FB_AUTH_LOGOUT_PAGE" ]; then
    AUTH_ARGS="$AUTH_ARGS --auth.logoutPage=${FB_AUTH_LOGOUT_PAGE}"
  fi
  # init crea il DB con la config auth; se il DB esiste già, config set la aggiorna
  # --createUserDir=true  → ogni nuovo utente riceve automaticamente /srv/<username> come scope
  # --scope=              → scope di default vuoto: MakeUserDir usa il nome utente come subdir
  if [ ! -f "/database/filebrowser.db" ]; then
    filebrowser config init --config="$config_file" $AUTH_ARGS #--createUserDir=true --scope=
  else
    filebrowser config set --config="$config_file" $AUTH_ARGS #--createUserDir=true --scope=
  fi
fi

exec filebrowser "$@"
