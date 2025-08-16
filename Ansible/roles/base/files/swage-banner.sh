#!/bin/bash

figurine -f "smslant.flf" Welcome To

# Choose a random entry
random_entry=$(cat /etc/profile.d/fontlist | shuf -n 1)

# Use the variable
figurine -f "$random_entry.flf" $(hostname -f)
