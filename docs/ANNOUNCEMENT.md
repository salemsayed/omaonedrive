# OmaOneDrive 1.6.2 announcement

Attach [the existing multi-account screenshot](images/panel-multi.png). This already-public image illustrates the panel using the QEMU test accounts.

## Discord

**OmaOneDrive 1.6.2 is out, with multi-account support ☁️**

Manage your configured OneDrive accounts from the Omarchy bar, with separate storage, activity, and controls for each one.

- Switch accounts directly in the panel.
- Pause one account while the others keep syncing.
- Set independent resume timers that survive a shell restart.
- Open the right account from notifications and folder shortcuts.
- Use Full or Compact layouts, with keyboard navigation.

This release also fixes panel dismissal, ignored automation commands, and cloud checks failing because of a database lock.

Tested on a live Omarchy desktop with two real Microsoft accounts: uploads, downloads, remote edits, account isolation, and automatic resume. Automated tests and QEMU checks cover the failure cases too.

**Update:**
```sh
omarchy plugin update io.github.salemsayed.omaonedrive
omarchy restart shell
```

**New install** (requires the OneDrive Client for Linux):
```sh
omarchy plugin add https://github.com/salemsayed/omaonedrive.git --enable
```

Release and verification report:
https://github.com/salemsayed/omaonedrive/releases/tag/v1.6.2

Feedback and bug reports welcome!

## Publication notes

The post covers the 1.6 update series, including the fixes in 1.6.1 and 1.6.2. Existing accounts must already be configured in the OneDrive client.

Marketplace compatibility has passed. Official marketplace verification remains pending maintainer approval of the [update request](https://github.com/omacom/omarchy-plugin-marketplace/issues/6957); do not describe the plugin as officially verified until that completes.
