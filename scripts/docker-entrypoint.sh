#!/bin/sh -e

# Install optional AUR packages, configure proxies, and execute the container command.
# Used inside Docker as the image entrypoint configured in Dockerfile.

if [ ! -z "$AUR_PACKAGES" ]; then
  aurman -S --noedit --noconfirm --pgp_fetch $AUR_PACKAGES
fi

# set proxy to system if needed
[ ! -z "$http_proxy" ] && echo "http_proxy=$http_proxy" >> /etc/environment
[ ! -z "$https_proxy" ] && echo "https_proxy=$https_proxy" >> /etc/environment

echo "> $@" && exec "$@"
