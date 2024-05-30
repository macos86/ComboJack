# ComboJack

![screen](./Installer/Screenshot.png)

Hackintosh combojack support for alc236 layout 68/alc256 layout 56/alc289 layout 68/alc295 layout 33.

-  Use bootargs `alcverbs=1` or DeviceProperties to audio pci-root `alc-verbs | DATA | 01000000`
-  For install run ComboJack_Installer/install.command and reboot
-  For uninstall run ComboJack_Installer/uninstall.command and reboot
-  When you attach a headphone there will be a popup asking about headphone type.
-  Refactor
-  Fix on sleep wake
-  Bug fix

## Building

### From GitHub:

Install Xcode, clone the GitHub repo and enter the top-level directory.  Then:

```sh
xcodebuild -configuration Release
```

Credits
-----

- [hackintosh-stuff](https://github.com/hackintosh-stuff) for creating [ComboJack](https://github.com/hackintosh-stuff/ComboJack)
- [vit9696](https://github.com/vit9696) for [AppleALC](https://github.com/acidanthera/AppleALC)
- [mbarbierato](https://github.com/mbarbierato) for developing
- [Lorys89](https://github.com/Lorys89) for setting alc verbs and add codec support
- [Linux code Source](https://github.com/torvalds/linux/blob/master/sound/pci/hda/patch_realtek.c)
