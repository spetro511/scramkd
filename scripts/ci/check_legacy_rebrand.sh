#!/usr/bin/env bash
# ==============================================================================
# scripts/ci/check_legacy_rebrand.sh
# Automated CI / Pre-Commit Safeguard: Zero Legacy Tactical* Brand Regressions
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

echo "=== [CI LINTER] Auditing repository for legacy Tactical* brand & symbol regressions ==="

VIOLATIONS=0

# 1. Check for strictly forbidden legacy target & symbol identifiers:
# - TacticalApp
# - TacticalCore
# - TacticalVirtualization
# - TacticalAudioSVS
# - CTacticalAudioRealtime
# - TacticalUI
FORBIDDEN_SYMBOLS_REGEX="TacticalApp|TacticalCore|TacticalVirtualization|TacticalAudioSVS|CTacticalAudioRealtime|TacticalUI"

echo "--> Scanning for forbidden legacy module & target names..."
# Find all tracked files and active documentation directories, ignoring .git, .build, .system_generated/logs, and binaries
FILES_TO_SCAN=$(git ls-files; ls docs/*.md ANTIGRAVITY_PROMPT.md AGENTS.md 2>/dev/null || true)
MATCHES=$(echo "$FILES_TO_SCAN" | sort -u | grep -vE '(\.png|\.jpg|\.jpeg|\.ico|\.icns|\.svg|\.pdf|\.woff|\.woff2|\.ttf|\.otf|\.system_generated/)' | while read -r file; do
    if [ -f "$file" ]; then
        # Exclude this script itself and migration skills if they list old -> new mappings
        if [[ "$file" == "scripts/ci/check_legacy_rebrand.sh" || "$file" == ".agents/AGENT_REBRAND_ARCHITECT.md" || "$file" == ".agents/skills/scramkd-rebrand-governance/SKILL.md" ]]; then
            continue
        fi
        grep -nE "($FORBIDDEN_SYMBOLS_REGEX)" "$file" | sed "s|^|$file:|g" || true
    fi
done)

if [ -n "$MATCHES" ]; then
    echo "❌ ERROR: Found forbidden legacy module/target identifiers in tracked files:"
    echo "$MATCHES"
    VIOLATIONS=$((VIOLATIONS + 1))
else
    echo "✅ No forbidden legacy module/target symbols found in tracked files."
fi

# 2. Check for legacy TacticalHypervisor references:
echo "--> Scanning for legacy 'TacticalHypervisor' references..."
TH_MATCHES=$(git ls-files | while read -r file; do
    if [ -f "$file" ]; then
        # Permitted exceptions: SECURITY.md (EOL notice) and docs/GITHUB_ISSUES_BACKLOG.md (backlog entry)
        if [[ "$file" == "SECURITY.md" || "$file" == "docs/GITHUB_ISSUES_BACKLOG.md" || "$file" == "scripts/ci/check_legacy_rebrand.sh" || "$file" == ".agents/AGENT_REBRAND_ARCHITECT.md" || "$file" == ".agents/skills/scramkd-rebrand-governance/SKILL.md" ]]; then
            continue
        fi
        grep -n "TacticalHypervisor" "$file" | sed "s|^|$file:|g" || true
    fi
done)

if [ -n "$TH_MATCHES" ]; then
    echo "❌ ERROR: Found unauthorized 'TacticalHypervisor' references:"
    echo "$TH_MATCHES"
    VIOLATIONS=$((VIOLATIONS + 1))
else
    echo "✅ No unauthorized 'TacticalHypervisor' references found."
fi

# 3. Check Swift Sources/ and Tests/ specifically for ANY occurrence of "Tactical" (case-insensitive)
echo "--> Scanning Sources/ and Tests/ for any occurrence of 'tactical'..."
SWIFT_MATCHES=$(grep -rn -i "tactical" Sources/ Tests/ 2>/dev/null || true)

if [ -n "$SWIFT_MATCHES" ]; then
    echo "❌ ERROR: Found 'tactical' in Swift Sources/ or Tests/:"
    echo "$SWIFT_MATCHES"
    VIOLATIONS=$((VIOLATIONS + 1))
else
    echo "✅ Zero occurrences of 'tactical' in Sources/ and Tests/."
fi

# 4. Check Package.swift and LaunchDaemons/ for any occurrence of "tactical" (case-insensitive)
echo "--> Scanning Package.swift and LaunchDaemons/ for any occurrence of 'tactical'..."
PKG_MATCHES=$(grep -rn -i "tactical" Package.swift LaunchDaemons/ 2>/dev/null || true)

if [ -n "$PKG_MATCHES" ]; then
    echo "❌ ERROR: Found 'tactical' in Package.swift or LaunchDaemons/:"
    echo "$PKG_MATCHES"
    VIOLATIONS=$((VIOLATIONS + 1))
else
    echo "✅ Zero occurrences of 'tactical' in Package.swift and LaunchDaemons/."
fi

# 5. Check for hardcoded workstation paths (/Users/) and file:// URIs (CWE-200 disclosure)
echo "--> Scanning for workstation paths (/Users/) and file:// URIs..."
PATH_MATCHES=$(git ls-files | while read -r file; do
    if [ -f "$file" ]; then
        # Permitted exceptions:
        # - MakerBreakerVirtualizationSecurityTests.swift (tests HOME=/Users/operator env scrubber)
        # - docs/GITHUB_ISSUES_BACKLOG.md (backlog description of CWE-200 rule)
        # - scripts/ci/check_legacy_rebrand.sh (this audit script)
        if [[ "$file" == "Tests/ScramKVirtualizationTests/MakerBreakerVirtualizationSecurityTests.swift" || \
              "$file" == "docs/GITHUB_ISSUES_BACKLOG.md" || \
              "$file" == "scripts/ci/check_legacy_rebrand.sh" ]]; then
            continue
        fi
        grep -nE "(/Users/|file://)" "$file" | sed "s|^|$file:|g" || true
    fi
done)

if [ -n "$PATH_MATCHES" ]; then
    echo "❌ ERROR: Found unauthorized workstation paths or file:// URIs (CWE-200):"
    echo "$PATH_MATCHES"
    VIOLATIONS=$((VIOLATIONS + 1))
else
    echo "✅ Zero unauthorized workstation paths (/Users/) or file:// URIs detected."
fi

echo "=== Linter Summary ==="
if [ "$VIOLATIONS" -eq 0 ]; then
    echo "🚀 AUDIT PASSED: All legacy brand, target, symbol identifiers, and path disclosure gates verified cleanly."
    exit 0
else
    echo "❌ AUDIT FAILED: $VIOLATIONS violation category/categories detected. Please correct before committing."
    exit 1
fi
