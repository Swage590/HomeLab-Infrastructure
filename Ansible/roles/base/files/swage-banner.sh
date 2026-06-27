#!/bin/bash
figurine -f "smslant.flf" Welcome To

if ! [ -f "/etc/profile.d/custom.png" ]; then
    # Choose a random entry
    random_entry=$(cat /etc/profile.d/fontlist | shuf -n 1)

    # Use the variable
    figurine -f "$random_entry.flf" $(hostname -f)

else
    timg "/etc/profile.d/custom.png"
fi

printf "%s | CPUs: %s | RAM: %s | Storage: %s/%s Used, %s Free\n" "$(lsb_release -ds)" "$(nproc)" "$(free -h | awk '/Mem:/ {print $2}')" "$(df -h / | awk 'NR==2 {print $3}')" "$(df -h / | awk 'NR==2 {print $2}')" "$(df -h / | awk 'NR==2 {print $4}')"

if [ $(apt-get --just-print upgrade | grep -c "^Inst") -gt 0 ]; then
    echo -e "\e[31m***Update Available***\e[0m"
fi
