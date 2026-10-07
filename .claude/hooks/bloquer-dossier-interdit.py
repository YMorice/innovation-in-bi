#!/usr/bin/env python3
"""Hook PreToolUse : bloque tout accès au dossier « 04 Qualification Outils Coupants ».

Le dossier contient des données de qualification d'outils coupants (essais
fournisseurs Guhring, KLENK, MAPAL…) qui ne doivent pas être lues, listées,
copiées, modifiées ni envoyées par Claude. Voir CLAUDE.md.

Code de sortie 2 = refus : le message sur stderr est renvoyé à Claude.
"""
import json
import os
import re
import sys

DOSSIER = "04 Qualification Outils Coupants"
RACINE = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
CIBLE = os.path.join(RACINE, DOSSIER)

MESSAGE = f"""ACCÈS REFUSÉ — dossier protégé : « {DOSSIER} »

Ce dossier est interdit à Claude, en lecture comme en écriture, par décision
explicite de Yann (voir CLAUDE.md, section « Dossier interdit »).
Il contient des données confidentielles de qualification d'outils coupants
(essais fournisseurs). Aucune opération n'est permise dessus : lecture,
listing, recherche, copie, déplacement, archivage, modification, suppression,
ni envoi vers un service externe.

Ce qu'il faut faire : ne pas contourner ce blocage (autre outil, glob, chemin
relatif, lien symbolique, recherche récursive depuis la racine…). Si la tâche
exige ce dossier, s'arrêter et demander à Yann de fournir lui-même les
informations nécessaires.
Raison du blocage : {{raison}}"""

# Commandes qui parcourent récursivement une arborescence.
RECURSIF = re.compile(
    r"(^|[\s;&|(`])("
    r"find|tree|du|rg|ag|ack|fd|mdfind|rsync|tar|zip|ditto|"
    r"grep\s+(-\w*[rR]\w*|--recursive)|ls\s+(-\w*R\w*)|cp\s+(-\w*[rR]\w*)|"
    r"chmod\s+-R|chown\s+-R|rm\s+(-\w*[rR]\w*)"
    r")\b"
)


def refuser(raison: str) -> None:
    print(MESSAGE.format(raison=raison), file=sys.stderr)
    sys.exit(2)


def normaliser(texte: str) -> str:
    # Retire échappements et guillemets pour attraper "04\ Qualification", '04 Qual…', etc.
    return re.sub(r"[\\'\"]", "", texte).lower()


def vise_dossier(texte: str) -> bool:
    t = normaliser(texte)
    if "qualification outils coupants" in t or "qualification*" in t:
        return True
    # "04 Q…", "04*", "04?" ou "04[" : raccourcis et globs vers le dossier.
    return re.search(r"(^|[\s/=(])04(\s*q|\*|\?|\[)", t) is not None


def chemin_dans_zone(chemin: str) -> bool:
    """Vrai si le chemin est la racine du projet (qui englobe le dossier) ou dedans."""
    if not chemin:
        return True
    p = os.path.realpath(os.path.join(RACINE, os.path.expanduser(chemin)))
    return p == RACINE or p == CIBLE or p.startswith(CIBLE + os.sep)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    outil = data.get("tool_name", "")
    entree = data.get("tool_input", {}) or {}

    # 1. Mention directe du dossier, quel que soit l'outil (y compris MCP, Agent…).
    if vise_dossier(json.dumps(entree, ensure_ascii=False)):
        refuser(f"l'outil {outil} cible explicitement le dossier protégé.")

    # 2. Chemins résolus (relatifs, symlinks, ..) pour les outils fichiers.
    for cle in ("file_path", "notebook_path", "path"):
        val = entree.get(cle)
        if isinstance(val, str) and val:
            p = os.path.realpath(os.path.join(RACINE, os.path.expanduser(val)))
            if p == CIBLE or p.startswith(CIBLE + os.sep):
                refuser(f"le chemin « {val} » se trouve dans le dossier protégé.")

    # 3. Recherches Glob/Grep lancées depuis la racine : elles descendraient dans le dossier.
    if outil in ("Glob", "Grep") and chemin_dans_zone(entree.get("path", "")):
        refuser(
            f"{outil} lancé depuis la racine du projet parcourrait le dossier protégé. "
            "Préciser un `path` qui ne l'englobe pas."
        )

    # 4. Commandes shell récursives depuis la racine du projet.
    if outil == "Bash":
        cmd = entree.get("command", "")
        cwd = os.path.realpath(data.get("cwd") or os.getcwd())
        depuis_racine = cwd == RACINE or RACINE in cmd or "innovation in bi" in normaliser(cmd)
        if RECURSIF.search(cmd) and depuis_racine:
            refuser(
                "commande récursive lancée depuis la racine du projet : elle "
                "parcourrait le dossier protégé. Cibler un fichier ou un sous-dossier précis."
            )
        if cwd == CIBLE or cwd.startswith(CIBLE + os.sep):
            refuser("le répertoire courant du shell est dans le dossier protégé.")

    sys.exit(0)


if __name__ == "__main__":
    main()
