#!/bin/bash
echo "[*] Checking Python code quality with Ruff..."
ruff check . --fix --unsafe-fixes
if ruff check .; then
    echo "[ok] Python code quality passed mandates."
else
    echo "[!] Python code quality issues found. Please fix according to mandates."
fi
