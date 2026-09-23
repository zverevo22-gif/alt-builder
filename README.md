# ALT Linux GNOME — сборка собственного ISO-образа

Набор скриптов для **сборки установочного ISO-образа ALT Linux GNOME**
с возможностью **изменения состава пакетов** и **брендирования**
(названия, графики, загрузчика, страниц приветствия, слайдов инсталлятора).

Сборка выполняется на штатном сборочном инструментарии ALT Linux —
**mkimage-profiles + mkimage + hasher**. Набор сам тянет свежую копию
`mkimage-profiles` из git.altlinux.org, накладывает на неё собственный
профиль `distro/alt-<де>` (выбор окружения: GNOME, Cinnamon или KDE Plasma)
и запускает сборку.

> Требование честности: собрать настоящий ISO возможно только в ALT-совместимом
> окружении (ALT Linux либо ALT Linux в контейнере/chroot), потому что
> `mkimage`/`hasher` являются частью дистрибутива ALT. На чистом Debian набор
> сам поднимает такой контейнер (см. раздел «Сборка на Debian»).

---

## 1. Требования

| Что               | Для чего                                  |
|-------------------|-------------------------------------------|
| Linux x86_64 (или arm64/aarch64) | собственно сборка                  |
| ~10–15 ГБ диска   | метапрофиль, chroot-кэши hasher, образ    |
| tmpfs на несколько ГБ (рекомендуется) | работа hasher (см. FAQ) |
| интернет          | клонирование метапрофиля, скачивание пакетов |
| ALT Linux         | среда сборки (либо Debian + поднимаемый контейнер) |

Зависимости, которые скрипты устанавливают сами (`--setup`):

- **ALT Linux**: `mkimage mkimage-preinstall hasher rsync git-core make bash`
- **Debian**: `podman` (или `docker.io`); остальное ставится внутри ALT-контейнера

---

## 2. Структура проекта

```
alt-gnome/
├── config/                      # ВСЯ настройка образа (правьте только здесь)
│   ├── build.conf               #   ветка, архитектура, окружение (DE), способ сборки
│   ├── branding.conf            #   брендинг (3 режима)
│   └── packages.conf            #   состав ПО (стадии, чёрный список)
├── scripts/
│   ├── build.sh                 # главная точка входа (см. ниже)
│   ├── gen-profile.sh           # формирование профиля/overlay mkimage-profiles
│   ├── build-iso.sh             # низкоуровневый запуск make -f main.mk
│   ├── env-setup-alt.sh         # подготовка среды на ALT Linux (--setup)
│   ├── env-setup-debian.sh      # подготовка ALT-контейнера на Debian (--setup)
│   ├── check-iso.sh             # проверка собранного ISO
│   ├── selfcheck.sh             # самопроверка набора (bash -n, структура)
│   └── clean.sh                 # очистка рабочего состояния
├── profile/                     # "оверлей" поверх mkimage-profiles
│   ├── conf.d/999-alt-desktop.mk.in    # шаблон субпрофиля distro/alt-<де>
│   ├── features.in/custom-brand/        # фича собственного брендинга
│   ├── pkg.in/lists/custom/             # ваши списки пакетов
│   └── branding/files/                  # BRANDING_MODE=files: дерево / инсталлятора
├── branding-template/           # источники собственного брендинга (repo-режим)
├── tools/
│   ├── make-aptconf.sh          # генерация APTCONF для hasher
│   └── mk-branding.sh           # сборка branding-<имя>-* и локального репозитория
├── work/                        # рабочее состояние (создаётся при сборке)
└── out/                         # готовые ISO (создаётся при сборке)
```

`work/` и `out/` пересоздаются автоматически и перечислены в `.gitignore`.

---

## 3. Как это устроено (кратко)

Сборку делает официальный `mkimage-profiles`. Набор добавляет к нему
один субпрофиль:

```make
# conf.d/999-alt-desktop.mk (генерируется из шаблона; <де> берётся из DESKTOP)
distro/alt-gnome: distro/regular-gnome use/blacklist-pkgs use/custom-brand
    @$(call add,THE_PACKAGES,...)
    @$(call add,THE_LISTS,...)
    ...
```

- **`distro/regular-<де>`** — полный состав штатной редакции ALT выбранного
  окружения: GNOME (`regular-gnome`), Cinnamon (`regular-cinnamon`) или KDE
  Plasma (`regular-kde`). X-сервер/композит, DE, дисплейный менеджер,
  install-профиль.
- **`use/blacklist-pkgs`** — штатная фича исключения пакетов.
- **`use/custom-brand`** — ваша фича (см. раздел «Брендирование»).

Пользовательские значения из `config/*.conf` передаются сборочному make
не через файл конфигурации, а **аргументами командной строки**
(файл `work/mkimage-vars.cnf`, значения экранируются `printf %q`). Это
исключает «утечку» какого-либо пользовательского конфига в профиль и
позволяет переопределять параметры на лету.

Жизненный цикл сборки (`build.sh`):

```
--setup        → env-setup-alt|debian      (только подготовка среды)
проверка изм.  → отпечаток config/ + profile/ + scripts/ (work/.profile-…)
               → если конфигурация НЕ менялась — профиль не пересобирается
gen-profile.sh → 1. клонировать/обновить mkimage-profiles (work/)
               → 2. наложить profile/ (merge, без удаления штатных файлов)
               → 3. сгенерировать conf.d/999-alt-desktop.mk (по DESKTOP)
               → 4. сгенерировать work/mkimage-vars.cnf
               → 5. сгенерировать хуки брендинга (features.in/custom-brand)
build-iso.sh   → make -r -f main.mk distro/alt-<де>.iso  (внутри work/..)
check-iso.sh   → проверка структуры ISO
автоочистка    → AUTOCLEAN=1 (по умолчанию): после УСПЕШНОЙ сборки удалить
                 временное BUILD-дерево mkimage + старые журналы (3 остаются)
```

**Проверка изменений при старте сборки.** `build.sh` не пересоздаёт профиль
слепо на каждом прогоне: по отпечатку содержимого `config/`, `profile/` и
скриптов формирования (`work/.profile-fingerprint.sha`) он решает, нужно ли
повторно запускать `gen-profile.sh`. Изменили конфигурацию/шаблоны — профиль
пересоберётся автоматически; ничего не меняли — он будет переиспользован
(быстрее и без «лишних» регенераций APTCONF).

**Автоочистка истории сборки.** После успешной сборки `build.sh` удаляет
большое временное BUILD-дерево mkimage (`work/mkimage-profiles.build`,
несколько ГБ) и оставляет только 3 последних журнала `out/build-*.log`.
Готовые ISO и сам сформированный профиль не трогаются. Управление —
`AUTOCLEAN` в `config/build.conf` (по умолчанию `1`); при `DEBUG=1`
автоочистка отключается.

**Выбор графического окружения перед сборкой.** `build.sh` спрашивает DE
интерактивно (если запуск идёт с терминала):

```
$ scripts/build.sh
[Ток] выберите графическое окружение (Enter = gnome):
 1) gnome
 2) cinnamon
 3) plasma
> 2
```

Можно и без вопроса — ключом `-d/--desktop` либо переменной окружения
`ALT_GNOME_DESKTOP`. Приоритет: ключ `-d` → переменная окружения → диалог →
значение в `config/build.conf` (`DESKTOP=`). Выбор действует на один запуск
(в конфигурацию не записывается).

```sh
scripts/build.sh -d plasma
ALT_GNOME_DESKTOP=cinnamon scripts/build.sh
```

То же окружение применяется и к другим ключам `build.sh`:
`--branch`/`--arch`/`--target`/`--out` передаются скриптам формирования
профиля через переменные `ALT_GNOME_*` и перекрывают соответствующие
значения из `config/*.conf` без их изменения на диске.

---

## 4. Быстрый старт

### 4.1. На ALT Linux

```sh
# 1. подготовка среды (от root; либо sudo):
sudo scripts/env-setup-alt.sh $(whoami)
#    если имя не указать — скрипт сам возьмёт $SUDO_USER, либо спросит
#    пользователя в диалоге (и предложит создать его, если тот отсутствует).

# 2. то же самое через build.sh (пользователя можно задать --user ИМЯ):
sudo scripts/build.sh --setup --user $(whoami)

#    env-setup-alt.sh сам идемпотентно настроит /etc/hasher-priv/system
#    (prefix=..., allowed_mountpoints=/proc /sys /dev /dev/pts,
#    allow_ttydev=yes) — без этого mkimage падает с ошибкой
#    "hasher's allowed_mountpoints do not include /proc".

# 2. перелогиньтесь (применение группы hasher), затем от обычного пользователя:
scripts/build.sh --check      # быстрая проверка конфигурации
scripts/build.sh              # полная сборка ISO
```

**ВАЖНО про root:** `mkimage`+`hasher` рассчитаны на обычного (не root)
пользователя. `build.sh` при запуске от root остановится с инструкцией —
это штатное поведение, а не ошибка. Если вы уже запускали сборку от root
и она упала — выполните подготовку и проверьте `/etc/hasher-priv/system`:

Результат — `out/alt-<де>-*.iso` (`alt-gnome-*`, `alt-cinnamon-*`, `alt-plasma-*`;
`<де>` — выбранное окружение, см. `config/build.conf`, `DESKTOP`). Журнал сборки
копируется в `out/build-*.log`.

### 4.2. На Debian/Ubuntu

```sh
# 1. установить podman или docker.io и подготовить ALT-контейнер:
scripts/build.sh --setup        # сам создаёт образ alt-gnome-builder

# 2. сборка (автоматически выполнится ВНУТРИ контейнера):
scripts/build.sh --check
scripts/build.sh
```

Подробности и ручные шаги — см. раздел 6.

---

## 5. Настройка состава ПО

### Выбор графического окружения (DESKTOP)

Окружение задаётся в `config/build.conf`:

```ini
# gnome (по умолчанию) | cinnamon | plasma
DESKTOP="gnome"
```

| `DESKTOP`  | Штатный профиль метапрофиля   | Цель сборки      | Образ на выходе   |
|------------|-------------------------------|------------------|-------------------|
| `gnome`    | `distro/regular-gnome`        | `distro/alt-gnome.iso`      | `alt-gnome-<дата>-x86_64.iso` |
| `cinnamon` | `distro/regular-cinnamon`     | `distro/alt-cinnamon.iso`   | `alt-cinnamon-…iso` |
| `plasma`   | `distro/regular-kde` (Plasma) | `distro/alt-plasma.iso`     | `alt-plasma-…iso` |

Изменение принимается уже при следующем `scripts/build.sh`: профиль и цель
формируются автоматически (старые `conf.d/999-alt-*.mk` удаляются). Если
нужен штатный образ «как в релизе ALT» без пользовательских правок — задайте
`TARGET="distro/regular-<де>.iso"` явно.

> Поскольку список пакетов (пары переменных ниже) один на все окружения,
> для Cinnamon/Plasma проверьте `THE_LISTS_EXTRA` в `config/packages.conf` —
> там может оставаться `custom/gnome-extra` (список GNOME-пакетов).

Все правки состава — только в `config/packages.conf` и файлах
`profile/pkg.in/lists/custom/`.

### Стадии формирования образа

| Переменная              | Куда добавляет пакеты                                                        |
|-------------------------|------------------------------------------------------------------------------|
| `THE_PACKAGES_EXTRA`    | устанавливаемая система **и** live-сессия                                   |
| `THE_LISTS_EXTRA`       | списки пакетов для той же стадии                                           |
| `BASE_PACKAGES_EXTRA`   | обязательная базовая система (осторожно)                                    |
| `MAIN_PACKAGES_EXTRA`   | пакеты, доступные для установки с носителя (дополнение к media-репо)        |
| `LIVE_PACKAGES_EXTRA`   | только live-сессия                                                         |
| `LIVE_LISTS_EXTRA`      | списки для live-сессии                                                     |
| `INSTALL2_PACKAGES_EXTRA`| пакеты самого инсталлятора (не попадают в устанавливаемую систему)        |
| `BLACKLIST_PKGS`        | пакеты, исключаемые из образа (имена/фрагменты через пробел)               |

Пакеты можно задавать:

- **именем** — `THE_PACKAGES_EXTRA="firefox telegram-desktop"`;
- **списком** — файл в `profile/pkg.in/lists/custom/`, например
  `custom/gnome-extra`, подключается как `THE_LISTS_EXTRA="custom/gnome-extra"`.
  Формат списка — имена пакетов по одному на строку; допустимы комментарии `#`.

> Пакеты должны существовать в репозитории ветки (`BRANCH`). Перед большим
> изменением состава полезен `scripts/build.sh --check`, который отработает
> стадию согласования списков и сообщит о недостающих пакетах.

### Как быстро добавить/убрать предустановленную программу

**Добавить** — два пути:

1. Прямо в `config/packages.conf`:

   ```ini
   # config/packages.conf
   THE_PACKAGES_EXTRA="firefox telegram-desktop vim"
   ```

2. Через файл-список (удобно для больших наборов и тематических групп):
   впишите имена пакетов по одному на строку в
   `profile/pkg.in/lists/custom/gnome-extra` (список уже подключён
   значением `THE_LISTS_EXTRA="custom/gnome-extra"`):

   ```
   # profile/pkg.in/lists/custom/gnome-extra (пример)
   firefox
   telegram-desktop
   vim
   #
   # каждый непустой фрагмент строки считается именем пакета
   ```

**Убрать предустановленную программу** (включая штатные пакеты окружения —
если знаете имя пакета) — чёрный список в том же файле:

```ini
# config/packages.conf
BLACKLIST_PKGS="cheese evolution"
```

`BLACKLIST_PKGS` принимает полные имена либо фрагменты имён пакетов через
пробел (маски-шаблоны не поддерживаются).

После любой правки состава:

```sh
scripts/build.sh --check   # быстрая проверка согласования списков
scripts/build.sh           # полная сборка с новым составом
```

**Куда попадёт пакет** (краткая памятка):

| Хочу                                     | Переменная                    |
|------------------------------------------|-------------------------------|
| поставить «по умолчанию» + в live        | `THE_PACKAGES_EXTRA`          |
| доступно для установки с диска, без автоустановки | `MAIN_PACKAGES_EXTRA` |
| только в live-сессии                     | `LIVE_PACKAGES_EXTRA`          |
| только в инсталляторе                    | `INSTALL2_PACKAGES_EXTRA`      |
| гарантированно в базе                    | `BASE_PACKAGES_EXTRA`          |
| исключить из образа                      | `BLACKLIST_PKGS`               |

---

## 6. Подробнее о средах сборки

### 6.1. ALT Linux

```sh
sudo scripts/env-setup-alt.sh $USER
```

Скрипт ставит пакеты, выдаёт пользователю права `hasher`
(`hasher-useradd`, группы `hashman`/`hasher`), нормализует
`/etc/hasher-priv/system`, создаёт `~/out`, `~/tmp` и `.gitconfig`. Дальше —
обычный пользователь (обязательно **новый вход** после `--setup`, чтобы
применились группы):

```sh
scripts/build.sh            # сборка
scripts/build.sh --debug    # отладочная (make -r с DEBUG=1, полный лог)
```

hasher для своей работы монтирует proc/dev/… в управляемый chroot и требует
root-привилегий через setuid/demon-помощника — это причина правила «собираем НЕ от
root» (демон `hasher-privd` вообще отказывает root: `invalid uid: 0`).
Проверка: `id -nG | grep -E 'hashman|hasher'`.

### 6.2. Debian/Ubuntu

Полноценная ALT-среда в контейнере:

```sh
scripts/build.sh --setup
```

Что делает `env-setup-debian.sh` (режим `container`):

1. находит `podman`/`docker`;
2. тянет образ ALT (`alt:p11`), внутри ставит сборочные пакеты и создаёт
   пользователя сборки `builder` (группа `hashman`/`hasher`);
3. фиксирует результат как образ `alt-gnome-builder`;
4. создаёт обёртку `work/debian/run-in-container.sh`, которая запускает
   сборку в контейнере с флагами, необходимыми hasher-у:
   `--privileged --userns=host --security-opt seccomp=unconfined`.

При повторном запуске `--setup` подготовленный образ не пересоздаётся
(сбросить: `podman rmi alt-gnome-builder`).

Экспериментальный режим `--mode chroot` готовит ALT rootfs в каталоге
`work/debian/chroot` из архива (`ALT_ROOTFS_TAR=/путь/rootfs.tar`); сборка
запускается `sudo chroot ...`. Он требует root на хосте и описан только как
запасной.

> Образ ALT внутри контейнера — обычный ALT Linux, поэтому сборка Go-кода
> или низкоуровневые проверки работают как на «железе».

---

## 7. Брендирование

Поведение задаётся в `config/branding.conf` (`BRANDING_MODE`).

### 7.1. `auto` — штатные брендинги ALT (по умолчанию)

```ini
BRANDING_MODE="auto"
BRANDING="alt-starterkit"      # или alt-sisyphus
```

Mkimage-profiles закрепляет в установленной системе пакеты
`branding-<BRANDING>-{release, alterator, bootsplash, bootloader, graphics,
indexhtml, notes, slideshow}` (`PINNED_PACKAGES ... :Essential`) — все 8
субпакетов должны существовать в репозитории выбранной ветки. Для p10/p9
готовым решением является `alt-starterkit`, для Сизифа — `alt-sisyphus`.

### 7.2. `repo` — собственные брендинг-пакеты

```sh
tools/mk-branding.sh --theme=mydistro --name="My Distro" --codename=veles
```

`mk-branding.sh`:

1. генерирует RPM-спеку из `branding-template/branding.spec.in`;
2. создаёт недостающие подкаталоги (`bootloader`, `graphics`, `bootsplash/…`,
   `release/` и др.), чтобы `%files` спеки не падал на отсутствии путей;
3. если в `branding-template/release/` нет файла `os-release`, **генерирует
   `/usr/lib/os-release` по умолчанию** (данные из `--name`, `--codename`…);
   если файл есть, в нём подставляются макросы `%%NAME%%` и т.д.;
4. собирает src.rpm и бинарные пакеты `branding-mydistro-{...}`;
5. создаёт локальный apt-репозиторий `work/apt.d/localrepo` (индекс `genbasedir`).

После этого в конфигурации:

```ini
# branding.conf
BRANDING_MODE=repo
BRANDING=mydistro
# build.conf
APT_MIRROR="file:///путь/до/alt-gnome/work/apt.d/localrepo"
```

и перезапустить `scripts/build.sh`.

Формат строки репозитория — `rpm [<vendor>] <корень-зеркала> <путь>/<arch> <компонент>`
(канонически: `rpm [p11] http://mirror.yandex.ru/altlinux p11/branch/x86_64 classic`);
`<vendor>` здесь — имя ветки, которой зеркало подписывается ключом (см.
`vendors.list.d` в `work/apt.d/<ветка>-<арх>/`). Для локального репозитория из
`mk-branding.sh` (плоская структура `genbasedir`: `<каталог>/<арх>/base`) это,
например: `rpm [p11] file:///путь/до/work/apt.d/localrepo x86_64 base`.

Наполнение каталогов `branding-template/{graphics,bootloader,bootsplash,
indexhtml,notes,slideshow,alterator}/` описано в
`branding-template/README.md`. Образцы реализации: официальный
`branding-alt-starterkit`.

### 7.3. `files` — копирование дерева файлов

```ini
BRANDING_MODE=files
```

Файлы из `profile/branding/files/` рекурсивно копируются в корень файловой
системы **инсталлятора** (они закладываются в `image-scripts.d/`),
например:

```
profile/branding/files/etc/os-release            → /etc/os-release
profile/branding/files/usr/share/pixmaps/logo.png → /usr/share/pixmaps/...
```

Это надёжный способ разложить тексты/файлы в инсталляторе. На проблемы
«а куда попали обои в установленной системе» режим `files` не отвечает —
для графики в устанавливаемой системе и live-сессии используйте `auto` или
`repo`.

Во всех режимах в ФС инсталлятора дополнительно создаётся
`/etc/custom-brand` с параметрами сборки (`@BRANDING@`, `@RELNAME@`,
`@VENDOR_NAME@`, дата сборки) хуком `99-custom-brand`.

Где и какое имя видно:

| Где                                                    | Источник имени                          | Как менять                                |
|--------------------------------------------------------|-----------------------------------------|-------------------------------------------|
| Меню загрузчика (grub/syslinux), live-сессия           | `RELNAME` (`999-alt-desktop.mk`: `set RELNAME`) | `config/branding.conf` → `RELNAME`  |
| `NAME`/`PRETTY_NAME` в live-образе (os-release), `/etc/custom-brand` | `RELNAME`                    | `config/branding.conf` → `RELNAME`  |
| Установленная система: `/etc/os-release`, `/etc/altlinux-release` | пакет `branding-<BRANDING>-release` | реестр `repo`: `tools/mk-branding.sh --name=...` (иначе останется ALT) |

Важно: `RELNAME` в `999-alt-desktop.mk` добавляется через `@$(call set,RELNAME,…)`
и **перекрывает** дефолт `set RELNAME,ALT ($(IMAGE_NAME))`, который задают
фичи grub/syslinux родительского профиля. Только изменения в
`config/branding.conf` недостаточно для установленной системы — её имя
формирует брендинг-пакет (см. 7.2, у `mk-branding.sh` для этого есть
`--name=`; генерируется `/usr/lib/os-release` в `branding-*-release`).

---

## 8. Проверка образа

```sh
scripts/check-iso.sh out/alt-*.iso
scripts/check-iso.sh --latest
```

Проверяет: наличие и объём файла; тип ISO-9660; MBR-признак гибридного
образа (смещение 510); ключевые элементы структуры ALT-образа (`.disk/`,
`ALTLinux/`, загрузчик `boot/grub`,`syslinux`/`isolinux`, `EFI/`); SHA-256.

Дополнительные проверки ISO после сборки:

```sh
isoinfo -d -i out/alt-*.iso                # метки/содержимое
mount -o loop out/alt-*.iso /mnt && ls /mnt   # содержимое
```

## 9. Очистка и повторные сборки

```sh
scripts/clean.sh          # убрать work/ и временные BUILDDIR в /tmp
scripts/clean.sh --out    # плюс удалить готовые образы из out/
scripts/build.sh --clean  # очистка перед очередной сборкой
```

Что именно чистит `scripts/clean.sh`:

- останавливает незавершённую сборку; в копии метапрофиля делает
  `make distclean` (`work/mkimage-profiles`);
- удаляет `work/` целиком — прежде всего накопленное дерево собранной
  файловой системы `work/mkimage-profiles.build/distro/…` (после сборки
  или прерванного прогона это **несколько гигабайт**);
- удаляет временные BUILDDIR из `/tmp` (`/tmp/mkimage-profiles.build.*`).

Что НЕ удаляется:

- готовые образы в `out/` (кроме `--out`);
- кэш hasher в `~/.hasher` — поэтому повторная сборка заметно быстрее
  первой;
- исходники/конфиги проекта (они всегда сохраняются).

Старые тестовые копии вне `work/` (`work-test/`, `work/debian` и т.п.)
`clean.sh` не трогает — их можно удалить вручную:

```sh
rm -rf work-test work/debian
```

Рабочее состояние полностью автогенерируемое: после `clean.sh` следующая
сборка начинается с `scripts/gen-profile.sh` (или сразу `scripts/build.sh`).

## 10. FAQ / диагностика

- **`hasher's allowed_mountpoints do not include /proc`; `suitable BUILDDIR
  unavailable`** — mkimage не может создать сборочный каталог. Самая частая
  первопричина (признак — рядом строка
  `/usr/libexec/hasher-priv/getconf.sh: Отказано в доступе`): пользователь не
  состоит в группе **hasher** и потому не может прочитать конфиг hasher-priv.
  Лечится подготовкой среды (от root): `sudo scripts/build.sh --setup`
  (или `sudo scripts/env-setup-alt.sh $USER`) — она выполнит `hasher-useradd`,
  добавит в группу `hasher`, допишет `/etc/hasher-priv/system`. **После этого
  обязательно перелогиньтесь** — новая группа применяется только при новом
  входе. Вручную: удостоверьтесь, что в `/etc/hasher-priv/system` есть
  объединённые строки
  ```sh
  prefix=/home:/tmp
  allowed_mountpoints=/proc /sys /dev /dev/pts
  allow_ttydev=yes
  ```
  Также **не запускайте сборку от root** — это другой источник того же падения.
- **`rm: ... Отказано в доступе` при наложении overlay** — в `work/` остались
  файлы другого владельца (обычно от первой сборки, запущенной от root).
  Передайте каталог пользователю сборки: `sudo chown -R $(whoami): ...`,
  точнее:
  ```sh
  sudo chown -R "$USER":"$(id -gn)" /home/program/alt-gnome
  ```
  (сценарий сам останавливается с этой подсказкой при таком раскладе).
- **«Нет прав на /dev/loop0», «mount: permission denied»** — собирающие
  пользователи не должны быть root; hasher монтирует сам. Проверьте группу:
  `id -nG` (нужна `hashman`/`hasher`), при необходимости
  `sudo hasher-useradd $USER` и новый вход.
- **«Packages are not available …» на стадии `check-lists`** — списки пакетов
  сверяются с aptbox-кэшем. По умолчанию сборка использует закреплённое
  зеркало целевой ветки (`USE_APTCONF=1`, см. `tools/make-aptconf.sh`) и к
  настройкам apt хост-системы не обращается вовсе. Если же вы отключили
  `USE_APTCONF` (`0`), aptbox строится по `/etc/apt/sources.list.d/*` хоста, и
  разница между хостом и веткой даст это падение: хост p11 + `BRANCH=p10` →
  кэш не найдёт `kernel-image-un-def`, `make-initrd-propagator` и т.п.
  Приведите `BRANCH` в соответствие с хостом и удалите старый BUILDDIR:
  `rm -rf /tmp/.private/$USER/mkimage-profiles.build`. Ожидаемые флейворы ядра:
  `p11/c10/c11 → 6.12`, `sisyphus → 6.18`, `p10/p9 → un-def`.
- **Медленно и много места** — монтируйте tmpfs под префикс hasher:
  ```sh
  sudo mount -t tmpfs -o size=8G tmpfs /home/$USER/hasher
  ```
  и укажите этот префикс в `/etc/hasher-priv/system`. Подробнее — в FAQ
  hasher (https://altlinux.org/hasher).
- **Ошибка на стадии пакетов «нет такого пакета»** — добавьте пакет в
  создаваемый репозиторий ветки или уберите его из конфигурации; сообщение
  содержит имя и стадию.
- **`BRANDING`-пакеты не находятся** — в выбранном `BRANCH` нет брендинга
  (например, отсутствует субпакет). Смените `BRANDING` на тот, что есть в
  ветке, или соберите свой (`repo`).
- **Образ и система называются «ALT», а не моим именем** — смотрите таблицу
  «где какое имя видно» в §7. `RELNAME` из `config/branding.conf` правит
  загрузчик, live-сессию и `/etc/custom-brand` (переопределяет дефолт
  grub/syslinux через `@$(call set,RELNAME,…)` в `999-alt-desktop.mk`).
  Имя **установленной** системы даёт пакет `branding-<BRANDING>-release` —
  для него нужен режим `BRANDING_MODE=repo` и
  `tools/mk-branding.sh --name=...`. Одного изменения `RELNAME` для
  установленной системы недостаточно. Проверить, что ваше значение реально
  в конфигурации профиля: `grep RELNAME work/mkimage-profiles/conf.d/999-alt-desktop.mk`.
- **Проблемы с сетью** — метапрофиль и все пакеты тянутся из интернета; при
  медленном канале используйте `APT_MIRROR` (см. `tools/make-aptconf.sh`).
- **Контейнер падает внутри hasher с "Operation not permitted"** — запустите
  контейнер с `--privileged --userns=host --security-opt seccomp=unconfined`
  (обёртка `work/debian/run-in-container.sh` уже делает это).
- **Не знаете, что за профиль получится** — `scripts/selfcheck.sh` сравнивает
  overlay со свежим `mkimage-profiles`, а `--check` прогоняет согласование
  списков до стадии записи ISO.

## 11. Официальные источники

- mkimage-profiles (метапрофиль): https://git.altlinux.org/gears/m/mkimage-profiles.git
- mkimage: https://git.altlinux.org/gears/m/mkimage.git
- hasher: https://git.altlinux.org/gears/h/hasher.git
- документация: https://altlinux.org/mkimage-profiles, https://altlinux.org/hasher

## 12. Лицензия

Материалы публикуются под лицензией GPL-2.0-or-later (как и upstream
инструменты ALT Linux). Настраивайте конфигурацию под свои нужды;
скрипты — это обвязка вокруг официального сборочного цикла.