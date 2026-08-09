#!/usr/bin/env python3
"""PostToolUse hook: avertit quand un document BMad depasse son budget de taille.

Lit le payload du hook sur stdin, mesure le fichier ecrit, et renvoie un
avertissement au modele via hookSpecificOutput.additionalContext.

Ne bloque JAMAIS (exit 0 systematique) : c'est un garde-fou, pas une barriere.
Une erreur interne est silencieuse — un hook qui plante ne doit pas casser une session.

Budgets surchargeables via {project-root}/_bmad/doc-budgets.json :
    {"story": {"warn": 20480, "hard": 30720}, ...}
"""

import json
import os
import sys

# La console Windows n'est pas en UTF-8 par defaut : sans ca, tout caractere
# non-ASCII sort en "?" et peut corrompre le JSON lu par Claude Code.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except (AttributeError, OSError):
    pass

# Budgets par defaut, en octets.
#   warn : on signale, la session continue normalement
#   hard : le document a clairement depasse son role, on propose une action
DEFAULTS = {
    # Une story = une unite de travail implementable. Au-dela, c'est un epic.
    "story": {"warn": 20 * 1024, "hard": 30 * 1024},
    # Documents de planification : au-dela, ils doivent etre shardes.
    "planning": {"warn": 40 * 1024, "hard": 60 * 1024},
    # Registres append-only : au-dela, il faut archiver les epics clos.
    "ledger": {"warn": 50 * 1024, "hard": 80 * 1024},
    # Tout autre markdown suivi.
    "default": {"warn": 50 * 1024, "hard": 100 * 1024},
}

ADVICE = {
    "story": (
        "Cette story depasse son budget. Une story de cette taille fait le travail "
        "d'un epic : decoupez-la en stories independantes plutot que de la laisser "
        "grossir. Verifiez aussi qu'elle CITE les sections d'architecture "
        "(chemin + plage de lignes) au lieu de les recopier."
    ),
    "planning": (
        "Ce document de planification depasse son budget et va etre charge en entier "
        "par chaque session qui le consulte. Shardez-le (bmad-shard-doc, decoupage "
        "niveau 2) en un dossier + index pour que les workflows ne chargent que la "
        "section utile."
    ),
    "ledger": (
        "Ce registre append-only depasse son budget. Il grossit a chaque story et ne "
        "retrecit jamais. Archivez les entrees des epics clos "
        "(scripts/archive-epic.py) pour que les sessions courantes cessent de payer "
        "les epics termines."
    ),
    "default": (
        "Ce document depasse son budget. S'il est lu par des workflows, decoupez-le "
        "pour qu'ils ne chargent que la partie utile."
    ),
}

LEDGER_NAMES = {"sprint-status.yaml", "sprint-status.yml", "deferred-work.md"}
PLANNING_NAMES = {"architecture.md", "prd.md", "epics.md", "product-brief.md"}
TRACKED_EXT = {".md", ".yaml", ".yml"}


def classify(path):
    """Retourne la categorie de budget d'un fichier d'apres son nom et son chemin."""
    name = os.path.basename(path).lower()
    parts = [p.lower() for p in path.replace("\\", "/").split("/")]

    if name in LEDGER_NAMES:
        return "ledger"
    if name in PLANNING_NAMES:
        return "planning"
    # Convention du kit : les stories sont prefixees epic-
    if name.startswith("epic-"):
        return "story"
    if "implementation-artifacts" in parts:
        return "story"
    if "planning-artifacts" in parts:
        return "planning"
    return "default"


def load_budgets(start_path):
    """Cherche _bmad/doc-budgets.json en remontant depuis le fichier ecrit."""
    budgets = {k: dict(v) for k, v in DEFAULTS.items()}
    d = os.path.dirname(os.path.abspath(start_path))
    for _ in range(12):
        candidate = os.path.join(d, "_bmad", "doc-budgets.json")
        if os.path.isfile(candidate):
            try:
                with open(candidate, "r", encoding="utf-8") as fh:
                    override = json.load(fh)
                for key, val in override.items():
                    if key in budgets and isinstance(val, dict):
                        budgets[key].update(val)
                    elif isinstance(val, dict):
                        budgets[key] = val
            except (OSError, ValueError):
                pass  # config illisible : on garde les defauts
            break
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return budgets


def human(n):
    return "%.1f Ko" % (n / 1024.0)


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except (ValueError, OSError):
        return 0

    tool_input = payload.get("tool_input") or {}
    tool_response = payload.get("tool_response") or {}
    path = (
        tool_input.get("file_path")
        or tool_response.get("filePath")
        or tool_input.get("notebook_path")
    )
    if not path:
        return 0

    ext = os.path.splitext(path)[1].lower()
    if ext not in TRACKED_EXT:
        return 0

    try:
        size = os.path.getsize(path)
    except OSError:
        return 0

    category = classify(path)
    budget = load_budgets(path).get(category, DEFAULTS["default"])
    warn = budget.get("warn", DEFAULTS["default"]["warn"])
    hard = budget.get("hard", DEFAULTS["default"]["hard"])

    if size < warn:
        return 0

    level = "DEPASSEMENT" if size >= hard else "Avertissement"
    limit = hard if size >= hard else warn
    name = os.path.basename(path)
    headline = "%s budget documentaire — %s : %s (seuil %s, categorie %s)" % (
        level, name, human(size), human(limit), category,
    )

    out = {
        "systemMessage": headline,
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": headline + "\n" + ADVICE[category],
        },
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # un hook ne casse jamais une session
