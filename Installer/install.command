#!/bin/bash

if [[ $EUID -ne 0 ]];
then
    exec sudo /bin/bash "$0" "$@"
fi

cd "$( dirname "${BASH_SOURCE[0]}" )"

# Clean legacy stuff
#
sudo launchctl unload /Library/LaunchDaemons/com.ComboJack.plist 2>/dev/null
sudo rm -rf /Library/Extensions/CodecCommander.kext
sudo rm -f /usr/local/bin/ALCPlugFix
sudo rm -f /Library/LaunchAgents/good.win.ALCPlugFix
sudo rm -f /Library/LaunchDaemons/good.win.ALCPlugFix
sudo rm -f /usr/local/bin/hda-verb
sudo rm -f /usr/local/share/ComboJack/Headphone.icns
sudo rm -f /usr/local/share/ComboJack/l10n.json

# install ComboJack
sudo mkdir /usr/local/bin
sudo cp ComboJack /usr/local/bin
sudo chmod 755 /usr/local/bin/ComboJack
sudo chown root:wheel /usr/local/bin/ComboJack
sudo spctl --add /usr/local/bin/ComboJack
# install Headphone.icns
sudo mkdir -p /usr/local/share/ComboJack/
sudo cp Headphone.icns /usr/local/share/ComboJack/
sudo chmod 644 /usr/local/share/ComboJack/Headphone.icns
# install com.ComboJack.plist
sudo cp com.ComboJack.plist /Library/LaunchDaemons/
sudo chmod 644 /Library/LaunchDaemons/com.ComboJack.plist
sudo chown root:wheel /Library/LaunchDaemons/com.ComboJack.plist
sudo launchctl load /Library/LaunchDaemons/com.ComboJack.plist
echo
echo "Please reboot! Also, it may be a good idea to turn off \"Use"
echo "ambient noise reduction\" when using an input method other than"
echo "the internal mic (meaning line-in, headset mic). As always: YMMV."
echo
echo "Enjoy!"
echo
exit 0
