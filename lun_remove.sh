#!/bin/bash
# lun_remove.sh - Usuwa pojedynczy LUN z systemu przed odprezentowaniem z macierzy.
# Workflow uzycia jest taki: 
# 1. sprawdzasz czy OS widzi LUNa i czy jest używany, w razie potrzeby odmontowujesz
# 2. odpalasz skrypt dla danego WWN/UID, sprawdzasz czy prawdiłowo znalazł scieżki
# 3. skrypt usuwa devy należące do danego obiektu multipath i sam ten obiekt
# 4. odprezentowujesz LUNy z poziomu macierzy
# 5. na serwerze robisz np. rescan-scsi-bus.sh -r aby usunąć nieistniejące już w OS LUNy
# Użycie: lun_remove.sh <WWN> - dry run
#         lun_remove.sh --commit <WWN> - usuwanie z potwierdzeniem

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

COMMIT=false

# ── argumenty ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--commit" ]]; then
    COMMIT=true
    shift
fi

if [[ $# -ne 1 || $EUID -ne 0 ]]; then
    echo "Użycie: $(basename "$0") [--commit] <WWN>"
    echo "  Bez --commit działa w trybie dry-run (nic nie zmienia)."
    exit 1
fi

WWN="${1,,}"          # lower case
WWN="${WWN//[: -]/}"  # usuń separatory

# ── nagłówek ─────────────────────────────────────────────────────────────────
echo ""
if $COMMIT; then
    echo -e "${RED}${BOLD}[ COMMIT ]${RESET} $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')"
else
    echo -e "${YELLOW}${BOLD}[ DRY-RUN ]${RESET} $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')"
fi
echo -e "WWN: ${BOLD}${WWN}${RESET}"
echo "────────────────────────────────────────────────"

# ── szukaj mapowania multipath ────────────────────────────────────────────────
# multipath -ll wypisuje wwid z prefiksem "3": (360050768018107e2c8...)
MPATH=$(multipath -ll 2>/dev/null \
    | awk -v wwn="$WWN" 'tolower($0) ~ wwn { print $1; exit }')

if [[ -z "$MPATH" ]]; then
    echo -e "${YELLOW}[WARN]${RESET}  Nie znaleziono mapowania multipath dla tego WWN."
else
    echo -e "${CYAN}[INFO]${RESET}  Mapowanie multipath: ${BOLD}${MPATH}${RESET}"
fi

# ── szukaj urządzeń blokowych ─────────────────────────────────────────────────
# lsblk wypisuje WWN z prefiksem "0x": 0x60050768018107e2c8...
mapfile -t DEVS < <(lsblk -o NAME,WWN -d -n 2>/dev/null \
    | awk -v wwn="$WWN" 'tolower($2) ~ wwn { print $1 }')

if [[ ${#DEVS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}[WARN]${RESET}  Nie znaleziono urządzeń blokowych przez lsblk, próbuję /dev/disk/by-id..."
    mapfile -t DEVS < <(find /dev/disk/by-id/ -name "scsi-*${WWN}*" ! -name "*-part*" \
        -exec readlink -f {} \; 2>/dev/null | awk -F'/' '{print $NF}' | sort -u)
fi

if [[ ${#DEVS[@]} -eq 0 ]] && [[ -z "$MPATH" ]]; then
    echo -e "${RED}[ERROR]${RESET} Nic nie znaleziono dla podanego WWN. Sprawdź czy WWN jest poprawny."
    exit 1
fi

if [[ ${#DEVS[@]} -gt 0 ]]; then
    echo -e "${CYAN}[INFO]${RESET}  Urządzenia blokowe (${#DEVS[@]}):"
    for DEV in "${DEVS[@]}"; do
        SIZE=$(lsblk -o SIZE -d -n "/dev/${DEV}" 2>/dev/null || echo "?")
        echo -e "          ${BOLD}${DEV}${RESET}  (${SIZE})"
    done
fi

echo "────────────────────────────────────────────────"

# ── potwierdzenie w trybie commit ─────────────────────────────────────────────
if $COMMIT; then
    echo -e "${YELLOW}${BOLD}Powyższe urządzenia zostaną usunięte z systemu.${RESET}"
    read -r -p "Kontynuować? [tak/NIE] " ANSWER
    if [[ "${ANSWER,,}" != "tak" ]]; then
        echo "Przerwano."
        exit 0
    fi
fi

# ── usuwanie ─────────────────────────────────────────────────────────────────

# 1. multipath
if [[ -n "$MPATH" ]]; then
    if $COMMIT; then
        multipath -f "$MPATH" \
            && echo -e "${GREEN}[OK]${RESET}    Usunięto mapowanie: ${MPATH}" \
            || echo -e "${RED}[ERROR]${RESET} Nie udało się usunąć mapowania: ${MPATH}"
        sleep 1
    else
        echo -e "${YELLOW}[DRY-RUN]${RESET} multipath -f ${MPATH}"
    fi
fi

# 2. urządzenia blokowe
for DEV in "${DEVS[@]}"; do
    DEL="/sys/block/${DEV}/device/delete"
    if $COMMIT; then
        if [[ -f "$DEL" ]]; then
            echo 1 > "$DEL" \
                && echo -e "${GREEN}[OK]${RESET}    Usunięto urządzenie: ${DEV}" \
                || echo -e "${RED}[ERROR]${RESET} Nie udało się usunąć: ${DEV}"
        else
            echo -e "${YELLOW}[WARN]${RESET}  Brak ścieżki delete dla: ${DEV}"
        fi
    else
        echo -e "${YELLOW}[DRY-RUN]${RESET} echo 1 > ${DEL}"
    fi
done

echo "────────────────────────────────────────────────"
echo -e "${GREEN}${BOLD}Gotowe.${RESET}"
