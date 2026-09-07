# KiNO!BERNIC - установка на приставку с компьютера.
#
# Запускать не отсюда, а двойным щелчком по «Установить KiNO!BERNIC.bat»
# рядом: он открывает окно и разрешает выполнение этого скрипта.
#
# Что умеет:
#   - найти карту приставки в картридере и определить прошивку по разметке;
#   - поставить или обновить приложение;
#   - удалить его, с данными или без;
#   - то же самое по сети, если на приставке включён SSH.
#
# Почему PowerShell, а не программа: скрипт видно глазами, он ничего не ставит
# в систему и не пугает Windows предупреждением о неизвестном издателе - для
# человека, который ставит стороннее приложение на приставку, это важнее
# красивого окна. Имена переменных латиницей намеренно: если файл когда-нибудь
# пересохранят без BOM, испортится только текст сообщений, а не сам скрипт.

$ErrorActionPreference = "Stop"
$APPNAME  = "KiNO!BERNIC"
$RELEASES = "https://api.github.com/repos/DoomRoot/kinobernic/releases/latest"
$HERE     = Split-Path -Parent $MyInvocation.MyCommand.Path

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Head($text) { Write-Host ""; Write-Host ("== " + $text) -ForegroundColor Cyan }

# ---------------------------------------------------------------- карты ----

# Прошивку узнаём по разметке карты, а не по метке тома: метку человек мог
# сменить, а папки создаёт сама прошивка.
function Find-Cards {
    $found = @()
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        $root = $drive.Root
        if (-not $root) { continue }
        try {
            if (Test-Path (Join-Path $root "MUOS\application")) {
                $found += [PSCustomObject]@{
                    Root = $root
                    Kind = "muOS"
                    Dir  = (Join-Path $root ("MUOS\application\" + $APPNAME))
                    Data = (Join-Path $root "MUOS\kinolab")
                }
            } elseif (Test-Path (Join-Path $root "Roms\APPS")) {
                $found += [PSCustomObject]@{
                    Root = $root
                    Kind = "stock"
                    Dir  = (Join-Path $root "Roms\APPS\kinobernic")
                    Data = (Join-Path $root "Roms\APPS\kinobernic\kinolab")
                }
            }
        } catch { }
    }
    return $found
}

function Card-Version($card) {
    $path = Join-Path $card.Dir "VERSION"
    if (Test-Path $path) { return (Get-Content $path -Raw).Trim() }
    return $null
}

function Card-Name($card) {
    if ($card.Kind -eq "muOS") { return "muOS" }
    return "стоковая прошивка"
}

function Pick-Card {
    $cards = @(Find-Cards)
    if ($cards.Count -eq 0) {
        Say "Карта приставки не найдена." Yellow
        Say "Вставьте её в картридер и убедитесь, что в «Этом компьютере» появился диск"
        Say "с папками MUOS и ARCHIVE (muOS) или Roms и anbernic (стоковая прошивка)."
        return $null
    }
    if ($cards.Count -eq 1) {
        $one = $cards[0]
        $ver = Card-Version $one
        if ($ver) { $what = "уже стоит версия " + $ver } else { $what = "приложения ещё нет" }
        Say ("Найдена карта: " + (Card-Name $one) + ", диск " + $one.Root + " - " + $what) Green
        return $one
    }
    Say "Найдено несколько карт:"
    for ($i = 0; $i -lt $cards.Count; $i++) {
        $ver = Card-Version $cards[$i]
        if ($ver) { $what = "версия " + $ver } else { $what = "приложения нет" }
        Say ("  " + ($i + 1) + ") " + $cards[$i].Root + " - " + (Card-Name $cards[$i]) + ", " + $what)
    }
    $answer = Read-Host "Номер карты"
    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $cards.Count) {
        return $cards[$n - 1]
    }
    Say "Не понял номер." Yellow
    return $null
}

# --------------------------------------------------------------- пакет ----

# Пакет ищем сначала рядом со скриптом: человек мог скачать его заранее, и
# тогда установка проходит совсем без сети.
function Find-Package {
    $near = Get-ChildItem -Path $HERE -Filter "*-install.zip" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($near) {
        Say ("Беру пакет рядом со скриптом: " + $near.Name)
        return $near.FullName
    }

    Head "Скачиваю последнюю версию"
    $tmp = Join-Path $env:TEMP ("kinobernic-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $json = Join-Path $tmp "release.json"
    & curl.exe -sL -o $json $RELEASES
    if (-not (Test-Path $json)) { throw "не удалось получить список релизов" }
    $release = Get-Content $json -Raw | ConvertFrom-Json
    $asset = $release.assets | Where-Object { $_.name -like "*-install.zip" } | Select-Object -First 1
    if (-not $asset) { throw ("в релизе " + $release.tag_name + " нет пакета установки (*-install.zip)") }
    $file = Join-Path $tmp $asset.name
    Say ("Версия " + $release.tag_name + ", файл " + $asset.name + " (" +
         [math]::Round($asset.size / 1KB) + " КБ)")
    & curl.exe -L --progress-bar -o $file $asset.browser_download_url
    if (-not (Test-Path $file)) { throw "скачать не вышло" }
    return $file
}

function Unpack-Package($zip) {
    $tmp = Join-Path $env:TEMP ("kinobernic-pkg-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    if (-not (Test-Path (Join-Path $tmp "stock")) -or -not (Test-Path (Join-Path $tmp "muos"))) {
        throw "в пакете нет папок stock и muos - это не пакет установки"
    }
    return $tmp
}

# ------------------------------------------------------------ установка ----

function Install-Card($card, $pkg) {
    if ($card.Kind -eq "muOS") { $from = Join-Path $pkg "muos" } else { $from = Join-Path $pkg "stock" }
    Head ("Ставлю на " + $card.Root)
    # Копируем содержимое, а не саму папку: внутри уже лежит раскладка карты.
    Copy-Item -Path (Join-Path $from "*") -Destination $card.Root -Recurse -Force

    $ver = Card-Version $card
    if (-not $ver) { throw "после копирования на карте нет файла VERSION - что-то пошло не так" }
    $must = @($card.Dir)
    if ($card.Kind -eq "muOS") {
        $must += (Join-Path $card.Dir "mux_launch.sh")
    } else {
        $must += (Join-Path $card.Root ("Roms\APPS\" + $APPNAME + ".sh"))
        $must += (Join-Path $card.Dir "fonts\LiberationSans-Regular.ttf")
    }
    foreach ($p in $must) { if (-not (Test-Path $p)) { throw ("не легло: " + $p) } }

    Say ("Готово: версия " + $ver + " на диске " + $card.Root) Green
    Say ""
    Say "Дальше: извлеките карту через значок в трее, вставьте в приставку и включите."
    if ($card.Kind -eq "muOS") {
        Say "Приложение появится в разделе «Приложения»."
    } else {
        Say "Приложение появится в разделе APPS."
    }
    Say "При первом запуске нужен Wi-Fi: приложение соберёт каталог фильмов."
}

function Remove-Card($card, $withData) {
    Head ("Удаляю с " + $card.Root)
    $paths = @($card.Dir)
    if ($card.Kind -eq "muOS") {
        $paths += (Join-Path $card.Root "MUOS\info\catalogue\Application\box\kinobernic.png")
        $paths += (Join-Path $card.Root "MUOS\info\catalogue\Application\grid\kinobernic.png")
        if ($withData) {
            $paths += $card.Data
            $paths += (Join-Path $card.Root "MUOS\log\kinobernic.log")
        }
    } else {
        $paths += (Join-Path $card.Root ("Roms\APPS\" + $APPNAME + ".sh"))
        $paths += (Join-Path $card.Root ("Roms\APPS\Imgs\" + $APPNAME + ".png"))
    }

    # На стоке данные лежат внутри папки приложения, поэтому «без данных»
    # означает: отложить их в сторону и вернуть на место после удаления.
    $kept = $null
    if ((-not $withData) -and $card.Kind -ne "muOS" -and (Test-Path $card.Data)) {
        $kept = Join-Path $env:TEMP ("kinolab-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        Copy-Item -Path $card.Data -Destination $kept -Recurse -Force
    }
    foreach ($p in $paths) {
        if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force; Say ("  убрано: " + $p) }
    }
    if ($kept) {
        New-Item -ItemType Directory -Path $card.Dir -Force | Out-Null
        Copy-Item -Path $kept -Destination $card.Data -Recurse -Force
        Remove-Item -Path $kept -Recurse -Force
        Say ("  данные оставлены: " + $card.Data)
    }
    Say "Удалено." Green
}

# ----------------------------------------------------------------- ssh ----

# Ключи приставок не запоминаем вовсе. `StrictHostKeyChecking=no` сам по себе
# спасает только от первого знакомства: он молча добавляет НОВЫЙ ключ, а если
# для этого адреса ключ уже записан и не совпал - ssh встаёт намертво
# («REMOTE HOST IDENTIFICATION HAS CHANGED») и заодно отключает вход по
# паролю. На домашней сети это происходит само собой: адреса раздаёт DHCP, и
# сегодняшний 192.168.2.40 - вчерашняя другая приставка. Ровно так и вышло:
# в known_hosts на .40 лежали ключи прежнего жильца, и удаление по сети
# отвалилось с кодом 255.
#
# NUL - это пустое устройство Windows: ключ некуда записать и не с чем
# сравнивать. Терять тут нечего, приставка стоит в домашней сети и пароль у
# неё «root»; зато файл ключей пользователя мы не трогаем ни на чтение, ни
# на запись.
$SSHOPT = @(
    "-o", "UserKnownHostsFile=NUL",
    "-o", "GlobalKnownHostsFile=NUL",
    "-o", "StrictHostKeyChecking=no"
)

function Ask-Address {
    Say ""
    Say "Приставка должна быть в той же сети, и на ней должен быть включён SSH."
    Say "  muOS:  Настройки → Сеть - подключить Wi-Fi; там же виден адрес."
    Say "         Затем Настройки → Служба → SSH - включить."
    Say "  Сток:  «Изменённые настройки системы» → «Служба SSH»."
    Say "         Адрес виден в настройках сети, вида 192.168.х.х"
    $ip = Read-Host "Адрес приставки"
    if (-not $ip) { return $null }
    return $ip
}

function Run-Ssh($ip, $script) {
    & ssh.exe @SSHOPT -o ConnectTimeout=8 ("root@" + $ip) $script
    if ($LASTEXITCODE -ne 0) { throw ("приставка не ответила или отказала, код " + $LASTEXITCODE) }
}

$INSTALL_SH = @'
set -e
ROOT=""
KIND=""
for M in /mnt/mmc /mnt/sdcard; do
    if [ -d "$M/MUOS/application" ]; then ROOT="$M"; KIND=muos; break; fi
    if [ -d "$M/Roms/APPS" ]; then ROOT="$M"; KIND=stock; break; fi
done
[ -n "$ROOT" ] || { echo "не нашёл карту приставки"; exit 1; }
rm -rf /tmp/kinobernic-pkg
mkdir -p /tmp/kinobernic-pkg
unzip -oq /tmp/kinobernic-install.zip "$KIND/*" -d /tmp/kinobernic-pkg
cp -a "/tmp/kinobernic-pkg/$KIND/." "$ROOT/"
rm -rf /tmp/kinobernic-pkg /tmp/kinobernic-install.zip
if [ "$KIND" = muos ]; then V=$(cat "$ROOT/MUOS/application/KiNO!BERNIC/VERSION")
else V=$(cat "$ROOT/Roms/APPS/kinobernic/VERSION"); fi
echo "поставлено: $KIND, версия $V, карта $ROOT"
'@

$REMOVE_SH = @'
set -e
KEEP=__KEEP__
DONE=0
for M in /mnt/mmc /mnt/sdcard; do
    if [ -d "$M/MUOS/application/KiNO!BERNIC" ]; then
        if [ "$KEEP" != 1 ]; then rm -rf "$M/MUOS/kinolab" "$M/MUOS/log/kinobernic.log"; fi
        rm -rf "$M/MUOS/application/KiNO!BERNIC"
        rm -f "$M/MUOS/info/catalogue/Application/box/kinobernic.png"
        rm -f "$M/MUOS/info/catalogue/Application/grid/kinobernic.png"
        echo "удалено с muOS ($M)"; DONE=1
    fi
    if [ -d "$M/Roms/APPS/kinobernic" ]; then
        rm -rf /tmp/kinolab-keep
        if [ "$KEEP" = 1 ] && [ -d "$M/Roms/APPS/kinobernic/kinolab" ]; then
            cp -a "$M/Roms/APPS/kinobernic/kinolab" /tmp/kinolab-keep
        fi
        rm -rf "$M/Roms/APPS/kinobernic" "$M/Roms/APPS/KiNO!BERNIC.sh"
        rm -f "$M/Roms/APPS/Imgs/KiNO!BERNIC.png"
        if [ -d /tmp/kinolab-keep ]; then
            mkdir -p "$M/Roms/APPS/kinobernic"
            cp -a /tmp/kinolab-keep "$M/Roms/APPS/kinobernic/kinolab"
            rm -rf /tmp/kinolab-keep
            echo "данные оставлены в $M/Roms/APPS/kinobernic/kinolab"
        fi
        echo "удалено со стоковой прошивки ($M)"; DONE=1
    fi
done
[ "$DONE" = 1 ] || echo "приложения на приставке не нашлось"
'@

function Install-Ssh($zip) {
    $ip = Ask-Address
    if (-not $ip) { return }
    Head ("Ставлю по сети на " + $ip)
    Say "Пароль спросит сама приставка: на обеих прошивках это root."
    & scp.exe @SSHOPT $zip ("root@" + $ip + ":/tmp/kinobernic-install.zip")
    if ($LASTEXITCODE -ne 0) { throw "не удалось скопировать пакет на приставку" }
    Run-Ssh $ip $INSTALL_SH
    Say ""
    Say "Готово. Приложение появится в списке, когда приставка вернётся в меню." Green
}

function Remove-Ssh($withData) {
    $ip = Ask-Address
    if (-not $ip) { return }
    Head ("Удаляю по сети с " + $ip)
    if ($withData) { $keep = "0" } else { $keep = "1" }
    Run-Ssh $ip $REMOVE_SH.Replace("__KEEP__", $keep)
    Say "Готово." Green
}

# ---------------------------------------------------------------- меню ----

Say ""
Say "  KiNO!BERNIC - установка на приставку" Cyan
Say "  ------------------------------------"
Say ""
Say "  1) Поставить или обновить - карта в картридере"
Say "  2) Удалить с карты"
Say "  3) Поставить или обновить по сети (SSH)"
Say "  4) Удалить по сети (SSH)"
Say "  5) Выход"
Say ""
$choice = Read-Host "Что делаем"

try {
    if ($choice -eq "1") {
        $card = Pick-Card
        if ($card) {
            $zip = Find-Package
            $pkg = Unpack-Package $zip
            Install-Card $card $pkg
            Remove-Item $pkg -Recurse -Force -ErrorAction SilentlyContinue
        }
    } elseif ($choice -eq "2") {
        $card = Pick-Card
        if ($card) {
            if (-not (Test-Path $card.Dir)) {
                Say "На этой карте приложения нет - удалять нечего." Yellow
            } else {
                Say ""
                Say "Удалить вместе с данными - каталог фильмов, вход в аккаунт, отметки просмотра?"
                $all = ((Read-Host "да / нет") -match "^(да|д|y|yes)$")
                Remove-Card $card $all
            }
        }
    } elseif ($choice -eq "3") {
        $zip = Find-Package
        Install-Ssh $zip
    } elseif ($choice -eq "4") {
        Say "Удалить вместе с данными - каталог, аккаунт, отметки просмотра?"
        $all = ((Read-Host "да / нет") -match "^(да|д|y|yes)$")
        Remove-Ssh $all
    } else {
        Say "Ничего не делаю."
    }
} catch {
    Say ""
    Say ("Не получилось: " + $_.Exception.Message) Red
    Say "На приставке ничего не сломано - можно закрыть окно и попробовать снова."
}

Say ""
Read-Host "Нажмите Enter, чтобы закрыть" | Out-Null
