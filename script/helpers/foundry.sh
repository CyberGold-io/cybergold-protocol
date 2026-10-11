#!/usr/bin/env bash
# shellcheck shell=bash

require_forge() {
  command -v forge >/dev/null 2>&1 || { echo "forge not found (install Foundry)"; exit 1; }
}

require_cast() {
  command -v cast >/dev/null 2>&1 || { echo "cast not found (install Foundry)"; exit 1; }
}
