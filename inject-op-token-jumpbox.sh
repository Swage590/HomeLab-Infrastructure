#!/bin/bash

# This script assumes you have already authenticated with the 1Password CLI
# by running: eval $(op signin)

OP_SERVICE_ACCOUNT_TOKEN=$(op read "op://Home Lab/co5dtojebigtletvoh2wwpsyl4/credential")
export OP_SERVICE_ACCOUNT_TOKEN
