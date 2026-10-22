#!/bin/sh
# Builds ./chain (optimised for size; no runtime dependencies beyond macOS).
cd "$(dirname "$0")" && swiftc -Osize -swift-version 5 -o chain main.swift && strip -x chain && echo "built ./chain"
