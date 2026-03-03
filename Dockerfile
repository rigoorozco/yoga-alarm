FROM agners/archlinuxarm:latest

MAINTAINER Rigo Orozco Díaz <rigo.orozco.d@gmail.com>

COPY sudoers.d/build /etc/sudoers.d/

RUN pacman-key --init && \
    pacman-db-upgrade && \
    update-ca-trust && \
    pacman -Syyu --noconfirm base-devel git archlinux-keyring curl tar \
    gcc devtools namcap xmlto docbook-xsl inetutils bc uboot-tools \
    meson linux-headers dtc ccache cmake awk && \
    useradd -d /usr/local/build -m -G wheel build

USER build

VOLUME /usr/local/build/src
USER build
RUN mkdir -p "$HOME/src"
WORKDIR /usr/local/build/src

COPY scripts/docker-entrypoint.sh /opt/bin/docker-entrypoint.sh
ENTRYPOINT ["/opt/bin/docker-entrypoint.sh"]

CMD sudo -E pacman -Sy && \
    makepkg -sfc --noconfirm --needed && \
    makepkg --printsrcinfo > .SRCINFO
