# robin-forge — parameterized AOSP/LineageOS build environment.
# One Dockerfile drives both bases via build-args (set from the device's device.conf):
#   UBUNTU_VER=20.04 JDK_VER=11   -> LineageOS 18.1 / Android 11 (msm8992 etc.)
#   UBUNTU_VER=24.04 JDK_VER=21   -> LineageOS 22.x / Android 15 (validated, see docs/los22-base)
# Host stays clean; the whole toolchain lives here. Runs as the host uid/gid so bind-mounted trees
# come out owned by you, not root.
ARG UBUNTU_VER=20.04
FROM ubuntu:${UBUNTU_VER}

ARG UBUNTU_VER
ARG JDK_VER=11
ARG UID=1000
ARG GID=1000
ENV DEBIAN_FRONTEND=noninteractive

# ncurses package names diverge between focal (versioned) and noble (unversioned). Pick per base so
# ONE Dockerfile serves both. Everything else in the AOSP dep list is common to 20.04 and 24.04.
#
# 22.04 needs BOTH: the unversioned packages for the build itself, and the versioned compat libs
# for AOSP's ancient RenderScript clang. lineage-20.0 still builds libclcore.bc with the 2016
# prebuilt clang-3289846, which is linked against the soname libncurses.so.5:
#   clang.real: error while loading shared libraries: libncurses.so.5: cannot open shared object
# jammy still carries libncurses5/libtinfo5 in universe. This is deliberately NOT folded into the
# wildcard branch: noble (24.04) dropped both packages, so installing them there fails the build.
RUN set -eux; \
    case "$UBUNTU_VER" in \
      20.04|18.04) NCURSES="lib32ncurses5-dev libncurses5-dev libncurses5" ;; \
      22.04)       NCURSES="lib32ncurses-dev libncurses-dev libncurses6 libncurses5 libtinfo5" ;; \
      *)           NCURSES="lib32ncurses-dev libncurses-dev libncurses6" ;; \
    esac; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\n' > /etc/apt/apt.conf.d/99forge; \
    ok=0; \
    for attempt in 1 2 3; do \
      if apt-get update && apt-get install -y --no-install-recommends --fix-missing \
          bc bison build-essential ccache curl flex g++-multilib gcc-multilib git git-lfs \
          gnupg gperf imagemagick lib32readline-dev lib32z1-dev liblz4-tool lzip xz-utils \
          libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop \
          pngcrush rsync schedtool squashfs-tools xsltproc zip unzip zlib1g-dev "openjdk-${JDK_VER}-jdk" \
          python-is-python3 python3 wget nano ca-certificates procps bsdmainutils \
          $NCURSES; then ok=1; break; fi; \
      echo "!! apt failed (attempt $attempt/3); retrying in 20s"; sleep 20; \
    done; \
    [ "$ok" = 1 ] || { echo "FATAL: apt failed three times -- distro mirror unreachable?"; exit 1; }; \
    command -v javac >/dev/null || { echo "FATAL: toolchain incomplete"; exit 1; }; \
    rm -rf /var/lib/apt/lists/*

# Google's repo tool.
RUN curl -sS https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo \
 && chmod +x /usr/local/bin/repo

# Build user matching the host uid/gid so bind-mounted files aren't root-owned.
# GOTCHA (24.04): the noble base ships a default 'ubuntu' user/group at uid/gid 1000 -> collides with
#   a host uid of 1000. Remove it first (harmless/no-op on focal, which has no such user).
# --no-log-init is CRITICAL on AD/LDAP-joined hosts: useradd seeds /var/log/{lastlog,faillog} indexed
#   BY UID, so a huge uid materializes a ~90 GB sparse file into the image layer. Skipping keeps it small.
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupdel ubuntu 2>/dev/null || true; \
    groupadd -g ${GID} builder 2>/dev/null || true; \
    useradd --no-log-init -u ${UID} -g ${GID} -m -s /bin/bash builder

USER builder
WORKDIR /aosp

ENV USE_CCACHE=1 \
    CCACHE_DIR=/ccache \
    CCACHE_EXEC=/usr/bin/ccache

RUN git config --global user.name  "builder" \
 && git config --global user.email "builder@localhost" \
 && git config --global color.ui   true

CMD ["/bin/bash"]
