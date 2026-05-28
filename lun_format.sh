#!/bin/bash
# =============================================================================
# lun_format.sh — TWORZY FILESYSTEMY XFS
# Wejście:  ten sam plik txt z WWN co lun_scan.sh (txt z lista LUN-ow)
# Wyjście:  na ekran: wwn -> UUID  (do skopiowania do Excela)
#
# Użycie: ./lun_format.sh <plik_wwn.txt>
#
# UWAGA: Ten skrypt modyfikuje urządzenia blokowe (mkfs.xfs).
#
# =============================================================================

set -uo pipefail

if [[ -t 1 ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

LOG="/var/log/lun_format_$(date +%Y%m%d_%H%M%S).log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

[[ $# -lt 1 ]] && { echo "Użycie: $0 <plik_wwn.txt>"; exit 1; }

WWN_FILE="$1"
[[ $EUID -eq 0 ]]    || { echo "Uruchom jako root"; exit 1; }
[[ -f "$WWN_FILE" ]] || { echo "Nie znaleziono pliku: $WWN_FILE"; exit 1; }

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  lun_format.sh — tworzenie filesystemów XFS${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "  Wejście: ${CYAN}$WWN_FILE${RESET}"
echo -e "  Log:     ${CYAN}$LOG${RESET}"
echo ""

# =============================================================================
# Faza 1 — TYLKO ODCZYT
# Skanuje WWN, pokazuje co znalazł, buduje listę do potwierdzenia.
# Nic nie jest jeszcze modyfikowane.
# =============================================================================
echo -e "${BOLD}Faza 1: weryfikacja (tylko odczyt)${RESET}"
echo ""

echo -e "${BOLD}Odczytuję mapę multipath...${RESET}"
MP_LL=$(multipath -ll 2>/dev/null) || { echo "BŁĄD: multipath -ll nie działa"; exit 1; }
echo ""

# Tablica: "wwn|dev|fs_type"
QUEUE=()

while IFS= read -r wwn || [[ -n "$wwn" ]]; do

    [[ -z "$wwn" || "$wwn" =~ ^[[:space:]]*# ]] && continue
    wwn=$(echo "$wwn" | tr -d '[:space:]')
    wwn_clean=$(echo "$wwn" | tr -d ':-' | tr '[:upper:]' '[:lower:]')

    echo -e "${BOLD}────────────────────────────────────────────────────────${RESET}"
    echo -e "  WWN: ${CYAN}${wwn_clean}${RESET}"

    mp_name=$(echo "$MP_LL" | grep -i "$wwn_clean" | awk '{print $1}' | head -1)

    if [[ -z "$mp_name" ]]; then
        echo -e "  ${RED}✗ Nie znaleziono w multipath — pomijam${RESET}"
        continue
    fi

    dev="/dev/mapper/$mp_name"

    if [[ ! -b "$dev" ]]; then
        echo -e "  ${RED}✗ $dev nie istnieje jako block device — pomijam${RESET}"
        continue
    fi

    size=$(lsblk -d -n -o SIZE "$dev" 2>/dev/null | tr -d ' ')
    [[ -z "$size" ]] && size="?"

    fs_type=$(blkid -o value -s TYPE "$dev" 2>/dev/null || echo "")
    [[ -z "$fs_type" ]] && fs_type="brak"

    echo -e "  Urządzenie: ${BOLD}$dev${RESET}"
    echo -e "  Rozmiar:    $size"

    if [[ "$fs_type" == "brak" ]]; then
        echo -e "  Filesystem: ${GREEN}brak — czysty LUN${RESET}"
    else
        echo -e "  Filesystem: ${YELLOW}$fs_type${RESET}"
    fi

    # VMFS / LVM — twarde blokowanie
    if [[ "$fs_type" == vmfs* || "$fs_type" == "LVM2_member" ]]; then
        echo -e "  ${RED}🚨 VMFS/LVM — blokuję bez pytania. Pomijam.${RESET}"
        continue
    fi

    # Istniejący FS — ostrzegamy, ale decyzja zapadnie przy potwierdzeniu per-LUN
    if [[ "$fs_type" != "brak" ]]; then
        echo -e "  ${YELLOW}⚠ Ma już filesystem — zostaniesz zapytany przed mkfs${RESET}"
    fi

    QUEUE+=("${wwn_clean}|${dev}|${fs_type}|${size}")

done < "$WWN_FILE"

echo ""

if [[ ${#QUEUE[@]} -eq 0 ]]; then
    echo "Brak LUNów do przetworzenia."
    exit 0
fi

# =============================================================================
# Faza 2 — Podsumowanie i globalne potwierdzenie
# =============================================================================
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  PLAN — LUNy do sformatowania (mkfs.xfs)${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo ""

for entry in "${QUEUE[@]}"; do
    IFS='|' read -r wwn dev fs_type size <<< "$entry"
    if [[ "$fs_type" == "brak" ]]; then
        echo -e "  $dev  ($size)  ${GREEN}czysty${RESET}"
    else
        echo -e "  $dev  ($size)  ${YELLOW}⚠ ma filesystem: $fs_type${RESET}"
    fi
done

echo ""
echo -e "${RED}${BOLD}UWAGA: mkfs.xfs nieodwracalnie niszczy dane na urządzeniu.${RESET}"
echo ""
read -rp "Wpisz TAK (wielkimi literami) żeby kontynuować: " confirm
[[ "$confirm" == "TAK" ]] || { echo "Anulowano."; exit 0; }

# =============================================================================
# Faza 3 — Wykonanie mkfs per LUN
# LUNy z istniejącym FS wymagają osobnego TAK.
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  WYNIKI  (wwn -> UUID)${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo ""

success=0
fail=0

for entry in "${QUEUE[@]}"; do
    IFS='|' read -r wwn dev fs_type size <<< "$entry"

    log "━━━ $dev ($wwn) ━━━"

    # Dodatkowe potwierdzenie dla LUNów z istniejącym FS
    if [[ "$fs_type" != "brak" ]]; then
        echo ""
        echo -e "  ${YELLOW}⚠ $dev ma filesystem $fs_type${RESET}"
        echo -e "  ${RED}mkfs.xfs ZNISZCZY istniejące dane!${RESET}"
        read -rp "  Wpisz TAK żeby nadpisać: " fs_confirm
        if [[ "$fs_confirm" != "TAK" ]]; then
            log "Pominięto $dev na życzenie użytkownika"
            echo -e "  ${YELLOW}Pominięto.${RESET}"
            (( fail++ ))
            continue
        fi
    fi

    # mkfs
    log "mkfs.xfs -K $dev"
    if ! mkfs.xfs -K "$dev" >> "$LOG" 2>&1; then
        log "✗ mkfs.xfs nie powiodło się dla $dev"
        echo -e "  ${RED}✗ mkfs.xfs nie powiodło się — sprawdź log: $LOG${RESET}"
        (( fail++ ))
        continue
    fi

    # Odczyt UUID
    uuid=$(blkid -o value -s UUID "$dev" 2>/dev/null || echo "")
    if [[ -z "$uuid" ]]; then
        log "✗ Nie można odczytać UUID dla $dev"
        echo -e "  ${RED}✗ Nie można odczytać UUID dla $dev${RESET}"
        (( fail++ ))
        continue
    fi

    log "✓ $wwn -> $uuid"
    # Wynik na ekran w formacie do skopiowania
    echo -e "  ${GREEN}✓${RESET}  $wwn  ->  $uuid"
    (( success++ ))

done

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "  Sukces: ${GREEN}$success${RESET}  |  Pominięto/błąd: ${RED}$fail${RESET}"
echo -e "  Log: ${CYAN}$LOG${RESET}"
echo ""
echo -e "${BOLD}Następny krok:${RESET}"
echo -e "  Wpisy fstab: ${CYAN}./lun_fstab.sh <plik_csv_ze_skryptu1>${RESET}"
echo ""
