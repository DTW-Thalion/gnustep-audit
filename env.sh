#!/bin/bash
# Source this before any GNUstep audit build command:
#   . ./env.sh
#
# Loads the full environment from ~/.profile

if [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
else
    echo "ERROR: ~/.profile not found" >&2
    return 1
fi
