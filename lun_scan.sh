#!/bin/bash
# =============================================================================
# lun_scan.sh — TYLKO ODCZYT
# Wejście:  plik txt z WWN (jeden na linię)
# Wyjście:  ekran — WWN -> /dev/mapper/..., rozmiar, typ FS
#
# Użycie: ./lun_scan.sh <plik_wwn.txt>
# =============================================================================

set -uo pipefail

if [[ -t 1 ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

[[ $# -lt 1 ]] && { echo "Użycie: $0 <plik_wwn.txt>"; exit 1; }

WWN_FILE="$1"
[[ $EUID -eq 0 ]]    || { echo "Uruchom jako root"; exit 1; }
[[ -f "$WWN_FILE" ]] || { echo "Nie znaleziono pliku: $WWN_FILE"; exit 1; }

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  lun_scan.sh — skanowanie LUNów (tylko odczyt)${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "  Wejście: ${CYAN}$WWN_FILE${RESET}"
echo ""

echo -e "${BOLD}Odczytuję mapę multipath...${RESET}"
MP_LL=$(multipath -ll 2>/dev/null) || { echo "BŁĄD: multipath -ll nie działa"; exit 1; }
echo ""

cnt_ok=0
cnt_fs=0
cnt_skip=0

while IFS= read -r wwn || [[ -n "$wwn" ]]; do

    [[ -z "$wwn" || "$wwn" =~ ^[[:space:]]*# ]] && continue
    wwn=$(echo "$wwn" | tr -d '[:space:]')
    wwn_clean=$(echo "$wwn" | tr -d ':-' | tr '[:upper:]' '[:lower:]')

    echo -e "${BOLD}────────────────────────────────────────────────────────${RESET}"
    echo -e "  WWN: ${CYAN}${wwn_clean}${RESET}"

    mp_name=$(echo "$MP_LL" | grep -i "$wwn_clean" | awk '{print $1}' | head -1)

    if [[ -z "$mp_name" ]]; then
        echo -e "  ${RED}✗ Nie znaleziono w multipath${RESET}"
        (( cnt_skip++ ))
        continue
    fi

    dev="/dev/mapper/$mp_name"

    if [[ ! -b "$dev" ]]; then
        echo -e "  ${RED}✗ $dev nie istnieje jako block device${RESET}"
        (( cnt_skip++ ))
        continue
    fi

    size=$(lsblk -d -n -o SIZE "$dev" 2>/dev/null | tr -d ' ')
    [[ -z "$size" ]] && size="?"

    fs_type=$(blkid -o value -s TYPE "$dev" 2>/dev/null || echo "")
    [[ -z "$fs_type" ]] && fs_type="brak"

    echo -e "  Dev:        ${BOLD}$dev${RESET}"
    echo -e "  Rozmiar:    $size"

    if [[ "$fs_type" == vmfs* || "$fs_type" == "LVM2_member" ]]; then
        echo -e "  Filesystem: ${RED}$fs_type  🚨 VMFS/LVM — datastore VMware lub dysk systemowy!${RESET}"
        (( cnt_skip++ ))
    elif [[ "$fs_type" == "brak" ]]; then
        echo -e "  Filesystem: ${GREEN}brak — czysty LUN${RESET}"
        (( cnt_ok++ ))
    else
        echo -e "  Filesystem: ${YELLOW}$fs_type${RESET}"
        (( cnt_fs++ ))
    fi

done < "$WWN_FILE"

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "  ${GREEN}Czyste LUNy:${RESET}       $cnt_ok"
echo -e "  ${YELLOW}Mają filesystem:${RESET}   $cnt_fs"
echo -e "  ${RED}Pominięte/błąd:${RESET}    $cnt_skip"
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo ""
