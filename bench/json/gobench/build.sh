#!/bin/sh
# usage: build.sh
# Builds ./prog-go, Go's encoding/json/v2 (and v1, for reference), as
# `prog-go MODE FILE N`, which prints "<ns> <check>" as the other
# competitors do. It needs Go 1.27 or later, where encoding/json/v2 needs
# no GOEXPERIMENT.
set -e
cd "$(dirname "$0")"
go build -trimpath -o prog-go .
