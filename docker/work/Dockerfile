# syntax=docker/dockerfile:1
# ベースイメージは compose.yaml の BASE_IMAGE (ubuntu:24.04 をインデックスのダイジェストで固定) で渡す

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG USER_UID=501
ARG USER_GID=20
ARG VPNSH_BUILD_HASH=unknown

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    EDITOR=vim

# パッケージ一覧 (packages.local.txt は個人用・任意。無くてもよい)
COPY packages.txt packages.local.tx[t] /tmp/vpnsh-packages/

# パッケージの更新・インストールと、setuid / setgid・ファイル capability の除去を1つの RUN で行う
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    apt-get update; \
    apt-get upgrade -y --no-install-recommends; \
    pkgs="$(cat /tmp/vpnsh-packages/* | sed -e 's/#.*//' | tr -s ' \t' '\n' | sed '/^$/d' | sort -u)"; \
    apt-get install -y --no-install-recommends $pkgs libcap2-bin; \
    rm -rf /tmp/vpnsh-packages; \
    find / -xdev -perm /6000 -type f -exec chmod a-s {} +; \
    getcap -r / 2>/dev/null | awk '{print $1}' | xargs -r setcap -r; \
    test -z "$(find / -xdev -perm /6000 -type f)"; \
    test -z "$(getcap -r / 2>/dev/null)"

# 一般ユーザー (UID/GID は Mac に合わせる。sudo は入れない)
RUN set -eux; \
    if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi; \
    if ! getent group "${USER_GID}" >/dev/null; then groupadd -g "${USER_GID}" vpnsh; fi; \
    # ホームに .bashrc / .profile などのひな形を置かない (設定は書き換えられない /etc/bash.bashrc に置く)
    find /etc/skel -mindepth 1 -delete; \
    useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash vpnsh; \
    test -z "$(ls -A /home/vpnsh)"; \
    git config --system safe.directory /work; \
    git config --system init.defaultBranch main

# VPNShell のスクリプト (root 所有。コンテナ内のユーザーからは書き換えられない)
COPY --chmod=0755 entrypoint.sh preflight.sh diag.sh ssh-relay /usr/local/lib/vpnsh/
# bash の設定は root 所有の /etc/bash.bashrc に置く (入れ子の bash でも同じ設定になる)
COPY --chmod=0644 bashrc /etc/bash.bashrc

LABEL org.opencontainers.image.title="vpnshell-work" \
      vpnshell.build-hash="${VPNSH_BUILD_HASH}"

USER vpnsh
WORKDIR /home/vpnsh
ENTRYPOINT ["/usr/local/lib/vpnsh/entrypoint.sh"]
CMD ["shell"]
