FROM menci/archlinuxarm:base-devel

MAINTAINER Rigo Orozco Díaz <rigo.orozco.d@gmail.com>

COPY sudoers.d/build /etc/sudoers.d/

# The base includes build tools and an initialized Arch Linux ARM keyring.
# ARM emulation/build kernels may lack Landlock support for pacman's downloader.
RUN pacman -Syu --needed --noconfirm --disable-sandbox base-devel git archlinuxarm-keyring curl tar \
    gcc devtools namcap xmlto docbook-xsl inetutils bc uboot-tools \
    meson linux-headers dtc ccache cmake gawk openssl libelf pahole python && \
    useradd -d /usr/local/build -m -G wheel build

# makepkg enables the compiler wrappers for all package builds.
RUN printf '\n# Enable compiler caching for package builds.\nBUILDENV+=(ccache)\n' >> /etc/makepkg.conf && \
    install -d -o build -g build /usr/local/build/.cache/ccache

USER build

VOLUME /usr/local/build/src
USER build
RUN mkdir -p "$HOME/src"
WORKDIR /usr/local/build/src

COPY scripts/docker/docker-entrypoint.sh /opt/bin/docker-entrypoint.sh
ENTRYPOINT ["/opt/bin/docker-entrypoint.sh"]

CMD sudo -E pacman -Sy --disable-sandbox && \
    makepkg -sfc --noconfirm --needed && \
    makepkg --printsrcinfo > .SRCINFO
