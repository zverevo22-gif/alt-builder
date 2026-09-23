#!/bin/bash
# ============================================================================
#  env-setup-debian.sh — подготовка ALT-окружения для сборки на Debian/Ubuntu
#
#  Полноценная сборка ALT-образа выполняется инструментами mkimage/hasher,
#  которые являются частью дистрибутива ALT Linux. Поэтому на чистом Debian
#  сборка протекает ВНУТРИ ALT Linux-контейнера (podman или docker).
#
#  Режимы:
#    container (по умолчанию) - постоянный ALT-контейнер с пользователем
#                               сборки builder (опытный образ сохраняется);
#    chroot (экспериментально) - подготовка корневой ФС ALT в каталоге
#                               work/debian/chroot (требует root-доступа
#                               хост-машины).
#
#  Использование:
#      scripts/env-setup-debian.sh [--mode container|chroot] [--image IMG]
#
#  При необходимости исходный образ ALT задаётся переменной ALT_IMAGE
#  (по умолчанию перебираются: alt:p10, altlinux/alt:p10).
# ============================================================================

source "$(dirname "$0")/lib/common.sh"

MODE="container"
ALT_IMAGE="${ALT_IMAGE:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="${2:?--mode требует значение}"; shift ;;
        --image) ALT_IMAGE="${2:?--image требует значение}"; shift ;;
        -h|--help) echo "usage: env-setup-debian.sh [--mode container|chroot] [--image IMG]"; exit 0 ;;
        *) die "неизвестная опция: $1" ;;
    esac
    shift
done

mkdir -p "${WORK_DIR}/debian"

# --- поиск runtime ------------------------------------------------------------
RUNTIME=""
for r in podman docker; do command -v "$r" >/dev/null 2>&1 && { RUNTIME="$r"; break; }; done
[ -n "$RUNTIME" ] || die "не найден podman/docker; установите, например: sudo apt-get install podman (Debian) или docker.io"

pick_image() {
    [ -n "$ALT_IMAGE" ] && { echo "$ALT_IMAGE"; return; }
    for img in "alt:p10" "altlinux/alt:p10"; do
        if $RUNTIME image exists "$img" 2>/dev/null; then echo "$img"; return; fi
    done
    echo "alt:p10"
}

if [ "$MODE" = "container" ]; then
    BASE_IMG="$(pick_image)"
    BUILDER_IMG="alt-gnome-builder"

    if $RUNTIME image exists "$BUILDER_IMG" >/dev/null 2>&1; then
        iok "образ сборки уже подготовлен: $BUILDER_IMG (обновите через --image для сброса)"
    else
        iprint "тянем базовый образ альт: $BASE_IMG"
        $RUNTIME pull "$BASE_IMG" || die "не удалось получить образ $BASE_IMG"

        iprint "устанавливаем сборочные пакеты и создаём пользователя builder (это займёт время)"
        SETUP_SH="set -e; \
apt-get update
apt-get install -y mkimage mkimage-preinstall hasher \
    rsync git-core make bash coreutils util-linux findutils sed grep || exit 1
groupadd -f hasher
id builder >/dev/null 2>&1 || useradd -m -s /bin/bash -G hasher builder
mkdir -p /home/builder/out /home/builder/tmp
chown -R builder: /home/builder/out /home/builder/tmp
echo setup-ok"

        # NB: --rm сознательно не используется: контейнер фиксируется (commit)
        if $RUNTIME run --name agn-builder-prep "$BASE_IMG" bash -c "$SETUP_SH"; then
            if $RUNTIME commit agn-builder-prep "$BUILDER_IMG" >/dev/null 2>&1; then
                $RUNTIME rm -f agn-builder-prep >/dev/null 2>&1 || true
                iok "опытный образ сборки зафиксирован: $BUILDER_IMG"
            else
                # podman/docker в некоторых конфигурациях запрещают commit
                $RUNTIME rm -f agn-builder-prep >/dev/null 2>&1 || true
                iwarn "не удалось зафиксировать образ; сборка будет переустанавливать пакеты каждый раз"
                BUILDER_IMG="$BASE_IMG"
            fi
        else
            $RUNTIME rm -f agn-builder-prep >/dev/null 2>&1 || true
            die "сбой подготовки пакетов внутри $BASE_IMG"
        fi
    fi

    # --- обёртка для запуска сборки в контейнере ------------------------------
    WRAP="${WORK_DIR}/debian/run-in-container.sh"
    cat > "$WRAP" <<EOF
#!/bin/bash
# сгенерировано; запуск ${PROJ_ROOT}/scripts/build.sh внутри ALT-контейнера
exec $RUNTIME run --rm \\
    --privileged \\
    --userns=host \\
    --security-opt seccomp=unconfined \\
    --security-opt label=disable \\
    -e ALT_GNOME_IN_CONTAINER=1 \\
    -v "$PROJ_ROOT":/build \\
    -w /build \\
    --user builder \\
    "$BUILDER_IMG" \\
    bash -c 'cd /build && exec bash scripts/build.sh "\$@"' _ "\$@"
EOF
    chmod +x "$WRAP"
    iok "обёртка создана: $WRAP (образ $BUILDER_IMG)"

elif [ "$MODE" = "chroot" ]; then
    CHROOT_DIR="${WORK_DIR}/debian/chroot"
    iwarn "режим chroot экспериментальный: требует root на хост-машине"
    [ "$(id -u)" = "0" ] || die "для chroot-режима нужны права root"
    if [ ! -d "$CHROOT_DIR/etc" ]; then
        TARBALL="${ALT_ROOTFS_TAR:-}"
        [ -n "$TARBALL" ] || die "укажите архив корневой ФС ALT: ALT_ROOTFS_TAR=/путь/к/rootfs.tar ./scripts/env-setup-debian.sh --mode chroot"
        mkdir -p "$CHROOT_DIR"
        tar -xpf "$TARBALL" -C "$CHROOT_DIR" || die "не удалось распаковать $TARBALL"
    fi
    chroot "$CHROOT_DIR" /bin/sh -c 'apt-get update && apt-get install -y mkimage mkimage-preinstall hasher rsync git-core make bash coreutils util-linux findutils sed grep'
    chroot "$CHROOT_DIR" /bin/sh -c 'groupadd -f hasher; id builder >/dev/null 2>&1 || useradd -m -s /bin/bash -G hasher builder'
    echo "chroot: $CHROOT_DIR (запуск сборки: sudo chroot $CHROOT_DIR /bin/bash -c 'cd /mnt && scripts/build.sh')" >&2
    iwarn "смонтируйте проект в chroot (mount --bind) перед сборкой"
else
    die "неизвестный режим: $MODE"
fi

iok "окружение для сборки подготовлено. Запустите: scripts/build.sh"
iok "предварительная проверка состава: scripts/build.sh --check"