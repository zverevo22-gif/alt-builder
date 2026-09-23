# Каталог брендинга (для BRANDING_MODE=repo)

Здесь лежат источники собственного набора пакетов брендинга.

- `branding.spec.in` — шаблон RPM-спеки; заполняются поля
  %%THEME%%, %%NAME%%, %%CODENAME%%, %%VERSION%%, %%RELEASE%%.
- Каталоги ниже — содержимое tarball `branding/`, который упаковывает
  `tools/mk-branding.sh`:

```
alterator/                 правки alterator (скрипты .x.pl, данные)
bootloader/                тема загрузчика grub2 (архитектура design)
bootsplash/plymouth/       тема plymouth (xxxx.plymouth, *.png, *.script)
bootsplash/bootsplash/     классический bootsplash (темы libraries/)
graphics/                  обои и элементы оформления (design)
indexhtml/                 страница приветствия index.html
notes/                     лицензия и заметки о выпуске
release/os-release         (опционально) свой os-release
slideshow/                 слайды инсталлятора
```

Все каталоги необязательны (кроме `graphics/`, если нужно оформление
рабочего стола, и `notes/` для текста лицензии). Пустые субпакеты не
создаются вообще, а наполненные — упаковываются в соответствующий
субпакет.

Сборка:

```
tools/mk-branding.sh --theme=mydistro --name="My Distro" --codename=veles
```

Подключение в конфигурации:

```
# branding.conf
BRANDING_MODE=repo
BRANDING=mydistro
# build.conf  (репозиторий из бинарных пакетов выше)
APT_MIRROR="file:///путь.до/alt-gnome/work/apt.d/localrepo"
```

См. полное описание в README.md (раздел «Брендирование»).